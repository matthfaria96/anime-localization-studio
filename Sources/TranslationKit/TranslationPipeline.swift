import CryptoKit
import Foundation
import SubtitleKit

public struct TranslationOptions: Sendable, Hashable, Codable {
    /// BCP 47; `nil` detects it from the lines.
    public var sourceLanguage: String?
    public var targetLanguage: String
    /// Previously translated lines sent with each batch (engines that use context).
    public var contextLines: Int
    /// `nil` uses the engine's preferred size.
    public var batchSize: Int?
    public var maxAttempts: Int
    public var translateKaraoke: Bool

    public init(sourceLanguage: String? = nil, targetLanguage: String = "pt-BR", contextLines: Int = 6, batchSize: Int? = nil,
                maxAttempts: Int = 3, translateKaraoke: Bool = false) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.contextLines = contextLines
        self.batchSize = batchSize
        self.maxAttempts = maxAttempts
        self.translateKaraoke = translateKaraoke
    }
}

public struct TranslationProgress: Sendable, Hashable {
    public var completed: Int
    public var total: Int
    public var message: String
    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

public struct TranslationReport: Sendable, Hashable, Codable {
    public var engineName: String
    public var sourceLanguage: String?
    public var targetLanguage: String
    public var totalLines: Int
    public var translatedLines: Int
    public var resumedLines: Int
    public var skipped: [String: Int]
    /// Lines whose inline tags were kept by translating the pieces between them separately.
    public var segmentFallbackLines: [Int]
    /// Lines already translated (by hand or a previous run) that were kept as they were.
    public var preservedLines: Int
    /// Lines left in the original language, with the reason.
    public var failedLines: [Int: String]
    public var glossaryViolations: [Glossary.Violation]
    public var structureProblems: [String]
    public var startedAt: Date
    public var finishedAt: Date

    public var isComplete: Bool { failedLines.isEmpty && structureProblems.isEmpty }
}

/// Saved after every batch so an interrupted translation resumes where it stopped.
public struct TranslationCheckpoint: Sendable, Hashable, Codable {
    public var sourceDigest: String
    public var engineID: String
    public var targetLanguage: String
    /// Final raw text (markup restored) per event index.
    public var translations: [Int: String]
    public var fallbackLines: Set<Int>
    public var updatedAt: Date

    public static func load(_ url: URL) -> TranslationCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranslationCheckpoint.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public enum TranslationPipelineError: Error, LocalizedError {
    case engineUnavailable(String)
    case aborted(String, completed: Int)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): m
        case .aborted(let m, let completed): "\(m) O progresso (\(completed) falas) foi salvo e pode ser retomado."
        }
    }
}

/// Translates every translatable line of a subtitle document and returns a new document in
/// which only event text changed. The source document is never modified.
public struct TranslationPipeline: Sendable {
    public let engine: any TranslationEngine
    public let glossary: Glossary
    public let options: TranslationOptions
    public let checkpointURL: URL?

    public init(engine: any TranslationEngine, glossary: Glossary = Glossary(), options: TranslationOptions = TranslationOptions(), checkpointURL: URL? = nil) {
        self.engine = engine
        self.glossary = glossary
        self.options = options
        self.checkpointURL = checkpointURL
    }

    struct Unit: Sendable {
        let index: Int
        let template: TranslatableText
        let speaker: String?
    }

    /// - Parameter existing: the current working translation. Every line whose text already
    ///   differs from the source (edited by hand, reviewed, or translated before) is kept and
    ///   not sent again; pass `nil` to translate everything from scratch.
    public func run(_ source: SubtitleDocument, existing: SubtitleDocument? = nil,
                    progress: (@Sendable (TranslationProgress) -> Void)? = nil) async throws -> (SubtitleDocument, TranslationReport) {
        let started = Date()
        let cues = source.cues
        var skipped: [String: Int] = [:]
        var units: [Unit] = []
        for cue in cues {
            if let reason = source.skipReason(at: cue.id, translateKaraoke: options.translateKaraoke) {
                skipped[reason.rawValue, default: 0] += 1
            } else if let template = source.translatable(at: cue.id) {
                units.append(Unit(index: cue.id, template: template, speaker: cue.actor.isEmpty ? nil : cue.actor))
            }
        }
        let sourceLanguage = options.sourceLanguage ?? AppleTranslationEngine.detectLanguage(of: units.map(\.template.body))
        let availability = await engine.availability(source: sourceLanguage, target: options.targetLanguage)
        if case .unavailable(let message) = availability { throw TranslationPipelineError.engineUnavailable(message) }
        if case .needsSetup(let message) = availability { throw TranslationPipelineError.engineUnavailable(message) }

        var state = State(checkpoint: loadCheckpoint(for: source))
        let resumed = state.checkpoint.translations.count
        var preserved = 0
        if let existing, existing.count == source.count {
            for unit in units where existing.rawText(at: unit.index) != source.rawText(at: unit.index) {
                state.checkpoint.translations[unit.index] = existing.rawText(at: unit.index)
                preserved += 1
            }
        }
        let context = TranslationContext(sourceLanguage: sourceLanguage, targetLanguage: options.targetLanguage,
                                         notes: glossary.notes, keepHonorifics: glossary.keepHonorifics)
        let batchSize = max(1, options.batchSize ?? engine.preferredBatchSize)
        let pending = units.filter { state.checkpoint.translations[$0.index] == nil }
        progress?(TranslationProgress(completed: units.count - pending.count, total: units.count, message: "Traduzindo…"))

        for start in stride(from: 0, to: pending.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            var batchContext = context
            batchContext.previousLines = previousLines(before: batch[0], units: units, state: state)
            batchContext.glossary = glossary.entries(occurringIn: batch.map(\.template.body))
            do {
                try await translate(batch, context: batchContext, state: &state)
            } catch let error as TranslationEngineError {
                // Permanent errors, and temporary ones that outlived every retry (server down,
                // rate limited), stop the episode instead of hammering the engine line by line.
                try saveCheckpoint(state)
                throw TranslationPipelineError.aborted(error.localizedDescription, completed: state.checkpoint.translations.count)
            }
            try saveCheckpoint(state)
            let done = units.count - pending.count + start + batch.count
            progress?(TranslationProgress(completed: done, total: units.count, message: "Traduzindo… \(done) de \(units.count)"))
        }

        var output = source
        for (index, text) in state.checkpoint.translations { output.setRawText(text, at: index) }
        var structure = StructureCheck.compare(source: source, translated: output)
        if let reparsed = try? SubtitleDocument.parse(output.encoded(), format: source.format) {
            structure.problems += StructureCheck.compare(source: source, translated: reparsed).problems
        } else {
            structure.problems.append("A legenda traduzida não pôde ser lida de volta.")
        }
        let plainSource = Dictionary(uniqueKeysWithValues: units.map { ($0.index, $0.template.body) })
        let plainTranslation = Dictionary(uniqueKeysWithValues: units.compactMap { unit in
            state.checkpoint.translations[unit.index].map { (unit.index, ASSText.plainText($0, htmlMarkup: source.usesHTMLMarkup)) }
        })
        let report = TranslationReport(
            engineName: engine.displayName, sourceLanguage: sourceLanguage, targetLanguage: options.targetLanguage,
            totalLines: units.count, translatedLines: state.checkpoint.translations.count, resumedLines: resumed,
            skipped: skipped, segmentFallbackLines: state.checkpoint.fallbackLines.sorted(), preservedLines: preserved, failedLines: state.failures,
            glossaryViolations: glossary.violations(source: plainSource, translation: plainTranslation),
            structureProblems: structure.problems, startedAt: started, finishedAt: Date())
        return (output, report)
    }

    // MARK: Batches

    struct State {
        var checkpoint: TranslationCheckpoint
        var failures: [Int: String] = [:]
    }

    /// Whole-line translation first; lines whose tags were lost, and engines that cannot keep
    /// placeholders, go piece by piece. A batch that keeps failing is split in half until the
    /// single line that breaks it is isolated and left untranslated, so one bad line never
    /// stops an episode.
    func translate(_ batch: [Unit], context: TranslationContext, state: inout State) async throws {
        let whole = batch.filter { engine.keepsPlaceholders || $0.template.placeholders.isEmpty }
        let pieces = batch.filter { !engine.keepsPlaceholders && !$0.template.placeholders.isEmpty }
        var needPieces = pieces
        if !whole.isEmpty {
            do {
                let lines = whole.enumerated().map { TranslationLine(id: $0.offset + 1, text: $0.element.template.body, speaker: $0.element.speaker) }
                let result = try await withRetries { try await engine.translate(lines, context: context) }
                for (offset, unit) in whole.enumerated() {
                    guard let text = result[offset + 1] else { state.failures[unit.index] = "sem resposta para a fala"; continue }
                    do {
                        state.checkpoint.translations[unit.index] = try unit.template.rebuild(translation: text)
                        state.failures[unit.index] = nil
                    } catch {
                        needPieces.append(unit)
                    }
                }
            } catch let error as TranslationEngineError {
                // Only a malformed answer is worth splitting (one line can break the JSON or the
                // context window); outages and quota errors go up to stop the run.
                guard case .invalidResponse = error else { throw error }
                if whole.count > 1 {
                    let middle = whole.count / 2
                    try await translate(Array(whole[..<middle]), context: context, state: &state)
                    try await translate(Array(whole[middle...]), context: context, state: &state)
                } else {
                    state.failures[whole[0].index] = error.localizedDescription
                }
            }
        }
        if !needPieces.isEmpty { try await translatePieces(needPieces, context: context, state: &state) }
    }

    private func translatePieces(_ units: [Unit], context: TranslationContext, state: inout State) async throws {
        var lines: [TranslationLine] = []
        var map: [(unit: Int, segment: Int)] = []
        for (u, unit) in units.enumerated() {
            for (s, segment) in unit.template.segments.enumerated() where segment.contains(where: { $0.isLetter || $0.isNumber }) {
                map.append((u, s))
                lines.append(TranslationLine(id: lines.count + 1, text: segment.trimmingCharacters(in: .whitespaces), speaker: unit.speaker))
            }
        }
        do {
            let result = try await withRetries { try await engine.translate(lines, context: context) }
            for (u, unit) in units.enumerated() {
                var segments = unit.template.segments
                var complete = true
                for (n, entry) in map.enumerated() where entry.unit == u {
                    if let text = result[n + 1] { segments[entry.segment] = text } else { complete = false }
                }
                guard complete, let rebuilt = try? unit.template.rebuild(segments: segments) else {
                    state.failures[unit.index] = "o motor não devolveu todas as partes da fala"
                    continue
                }
                state.checkpoint.translations[unit.index] = rebuilt
                state.checkpoint.fallbackLines.insert(unit.index)
                state.failures[unit.index] = nil
            }
        } catch let error as TranslationEngineError {
            guard case .invalidResponse = error else { throw error }
            for unit in units { state.failures[unit.index] = error.localizedDescription }
        }
    }

    /// Retries temporary failures with exponential backoff (1 s, 3 s, 9 s…).
    func withRetries<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as TranslationEngineError where error.isRetryable && attempt + 1 < options.maxAttempts {
                attempt += 1
                try await Task.sleep(for: .seconds(pow(3, Double(attempt - 1))))
            }
        }
    }

    private func previousLines(before unit: Unit, units: [Unit], state: State) -> [TranslationContext.PreviousLine] {
        guard engine.usesContext, options.contextLines > 0, let position = units.firstIndex(where: { $0.index == unit.index }) else { return [] }
        return units[..<position].suffix(options.contextLines * 2).compactMap { previous in
            state.checkpoint.translations[previous.index].map {
                .init(speaker: previous.speaker, source: previous.template.body, translation: ASSText.plainText($0))
            }
        }.suffix(options.contextLines)
    }

    // MARK: Checkpoints

    static func digest(of document: SubtitleDocument) -> String {
        SHA256.hash(data: document.encoded()).map { String(format: "%02x", $0) }.joined()
    }

    private func loadCheckpoint(for source: SubtitleDocument) -> TranslationCheckpoint {
        let digest = Self.digest(of: source)
        if let url = checkpointURL, let saved = TranslationCheckpoint.load(url),
           saved.sourceDigest == digest, saved.engineID == engine.id, saved.targetLanguage == options.targetLanguage {
            return saved
        }
        return TranslationCheckpoint(sourceDigest: digest, engineID: engine.id, targetLanguage: options.targetLanguage,
                                     translations: [:], fallbackLines: [], updatedAt: Date())
    }

    private func saveCheckpoint(_ state: State) throws {
        guard let url = checkpointURL else { return }
        var checkpoint = state.checkpoint
        checkpoint.updatedAt = Date()
        try checkpoint.save(to: url)
    }
}
