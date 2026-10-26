import Foundation
import Testing
import Translation
@testable import SubtitleKit
@testable import TranslationKit

/// Test double: wraps each line as `PT(<text>)`, keeping placeholders, with injectable faults.
final class ScriptedEngine: TranslationEngine, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    let keepsPlaceholders: Bool
    let usesContext = true
    let preferredBatchSize: Int
    private let lock = NSLock()
    private var calls: [[TranslationLine]] = []
    private var contexts: [TranslationContext] = []
    /// Fails (transiently) any batch that contains this text.
    var poison: String?
    /// Drops placeholders from whole lines (simulates an engine that mangles markup).
    var dropPlaceholders = false
    /// Throws a permanent error after this many calls.
    var failPermanentlyAfter: Int?

    init(keepsPlaceholders: Bool = true, batchSize: Int = 3) {
        self.keepsPlaceholders = keepsPlaceholders
        self.preferredBatchSize = batchSize
    }

    var callCount: Int { lock.withLock { calls.count } }
    var lastContext: TranslationContext? { lock.withLock { contexts.last } }
    var allLines: [TranslationLine] { lock.withLock { calls.flatMap { $0 } } }
    var allContexts: [TranslationContext] { lock.withLock { contexts } }

    func availability(source: String?, target: String) async -> EngineAvailability { .available }

    func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String] {
        let count: Int = lock.withLock {
            calls.append(lines)
            contexts.append(context)
            return calls.count
        }
        if let limit = failPermanentlyAfter, count > limit { throw TranslationEngineError.permanent("quota acabou") }
        if let poison, lines.contains(where: { $0.text.contains(poison) }) { throw TranslationEngineError.invalidResponse("veneno") }
        return Dictionary(uniqueKeysWithValues: lines.map { line in
            var text = line.text
            if dropPlaceholders { text = text.replacing(/⟦\d+⟧/, with: "") }
            return (line.id, "PT(\(text))")
        })
    }
}

func episode() throws -> SubtitleDocument {
    let url = try #require(Bundle.module.url(forResource: "episode", withExtension: "ass", subdirectory: "Fixtures"))
    return try SubtitleDocument.load(url)
}

@Suite("Translation pipeline")
struct TranslationPipelineTests {
    @Test func translatesOnlyTextAndKeepsStructure() async throws {
        let source = try episode()
        let engine = ScriptedEngine()
        let (output, report) = try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en", maxAttempts: 1)).run(source)
        #expect(report.structureProblems.isEmpty)
        #expect(report.isComplete)
        #expect(report.translatedLines == 6)
        #expect(report.skipped["comment"] == 1 && report.skipped["karaoke"] == 1 && report.skipped["drawing"] == 1)
        #expect(output.rawText(at: 1) == "PT(I won't let you hurt my friends!)")
        #expect(output.rawText(at: 2) == #"PT(Wait, Kirito-kun... {\i1}where{\i0} are you going?)"#)
        #expect(output.rawText(at: 4) == #"{\an8\pos(960,120)\fad(200,200)\t(0,500,\fscx120)}PT(The Town of Beginnings)"#)
        // Untranslatable lines are byte-identical.
        #expect(output.rawText(at: 5) == source.rawText(at: 5))
        #expect(output.rawText(at: 6) == source.rawText(at: 6))
        #expect(StructureCheck.compare(source: source, translated: output).isValid)
        // Speakers reach the engine.
        #expect(engine.allLines.first?.speaker == "Kirito")
    }

    @Test func previousLinesAndGlossaryAreSent() async throws {
        let glossary = Glossary(entries: [GlossaryEntry(source: "Town of Beginnings", target: "Cidade do Início", kind: .place)],
                                notes: "Kirito e Asuna são parceiros.")
        let engine = ScriptedEngine(batchSize: 2)
        _ = try await TranslationPipeline(engine: engine, glossary: glossary, options: .init(sourceLanguage: "en", contextLines: 2)).run(try episode())
        #expect(engine.callCount == 3)
        let contexts = engine.allContexts
        #expect(contexts[0].previousLines.isEmpty)
        #expect(contexts[1].previousLines.count == 2)
        #expect(contexts[1].glossary.map(\.target) == ["Cidade do Início"])
        #expect(contexts[1].notes.contains("parceiros"))
    }

    @Test func lostPlaceholdersFallBackToPieces() async throws {
        let engine = ScriptedEngine()
        engine.dropPlaceholders = true
        let (output, report) = try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en")).run(try episode())
        #expect(report.segmentFallbackLines == [2])
        #expect(output.rawText(at: 2) == #"PT(Wait, Kirito-kun...) {\i1}PT(where){\i0} PT(are you going?)"#)
        #expect(report.isComplete)
    }

    @Test func enginesWithoutPlaceholdersGoPieceByPiece() async throws {
        let engine = ScriptedEngine(keepsPlaceholders: false)
        let (output, report) = try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en")).run(try episode())
        #expect(output.rawText(at: 2).contains(#"{\i1}PT(where){\i0}"#))
        #expect(!engine.allLines.contains { $0.text.contains("⟦") })
        #expect(report.isComplete)
    }

    @Test func aBadLineIsIsolatedWithoutStoppingTheEpisode() async throws {
        let engine = ScriptedEngine(batchSize: 6)
        engine.poison = "75th floor"
        let (output, report) = try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en", maxAttempts: 1)).run(try episode())
        #expect(report.failedLines.keys.sorted() == [3])
        #expect(report.translatedLines == 5)
        #expect(output.rawText(at: 3) == (try episode()).rawText(at: 3))
        #expect(!report.isComplete)
    }

    @Test func resumesFromCheckpointAfterAPermanentFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSCheckpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = dir.appendingPathComponent("checkpoint.json")
        let first = ScriptedEngine(batchSize: 2)
        first.failPermanentlyAfter = 1
        await #expect(throws: TranslationPipelineError.self) {
            try await TranslationPipeline(engine: first, options: .init(sourceLanguage: "en"), checkpointURL: checkpoint).run(try episode())
        }
        #expect(TranslationCheckpoint.load(checkpoint)?.translations.count == 2)

        let second = ScriptedEngine(batchSize: 2)
        let (_, report) = try await TranslationPipeline(engine: second, options: .init(sourceLanguage: "en"), checkpointURL: checkpoint).run(try episode())
        #expect(report.resumedLines == 2)
        #expect(report.translatedLines == 6)
        #expect(second.allLines.count == 4)
    }

    @Test func checkpointForAnotherFileIsIgnored() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSCheckpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let checkpoint = dir.appendingPathComponent("checkpoint.json")
        try TranslationCheckpoint(sourceDigest: "other", engineID: "scripted", targetLanguage: "pt-BR", translations: [1: "X"], fallbackLines: [], updatedAt: Date())
            .save(to: checkpoint)
        let (output, report) = try await TranslationPipeline(engine: ScriptedEngine(), options: .init(sourceLanguage: "en"), checkpointURL: checkpoint).run(try episode())
        #expect(report.resumedLines == 0)
        #expect(output.rawText(at: 1) != "X")
    }

    @Test func cancellationStopsAndKeepsProgress() async throws {
        let engine = SlowEngine()
        let task = Task { try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en")).run(try episode()) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func existingTranslationsAreKept() async throws {
        let source = try episode()
        var existing = source
        existing.setRawText("Tradução feita à mão", at: 1)
        let engine = ScriptedEngine(batchSize: 10)
        let (output, report) = try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en")).run(source, existing: existing)
        #expect(output.rawText(at: 1) == "Tradução feita à mão")
        #expect(report.preservedLines == 1)
        #expect(!engine.allLines.contains { $0.text.contains("hurt my friends") })
        #expect(report.translatedLines == 6)
    }

    @Test func outagesStopTheRunInsteadOfSplitting() async throws {
        let engine = DownEngine()
        await #expect(throws: TranslationPipelineError.self) {
            try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en", batchSize: 6, maxAttempts: 2)).run(try episode())
        }
        #expect(engine.calls == 2)
    }

    @Test func glossaryViolationsAreReported() {
        let glossary = Glossary(entries: [GlossaryEntry(source: "Asuna", target: "Asuna", kind: .character)])
        let violations = glossary.violations(source: [1: "Wait, Asuna!", 2: "Asunaro"], translation: [1: "Espera, Assuna!", 2: "Asunaro"])
        #expect(violations.map(\.lineID) == [1])
    }

    @Test func parsesLooseJSON() throws {
        let reply = "```json\n{\"translations\":[{\"id\":\"1\",\"text\":\"Oi\"},{\"id\":2,\"text\":\"Tchau\"}]}\n```"
        #expect(try PromptBuilder.parseJSONTranslations(reply) == [1: "Oi", 2: "Tchau"])
        #expect(throws: TranslationEngineError.self) { try PromptBuilder.parseJSONTranslations("nada") }
    }
}

private final class DownEngine: TranslationEngine, @unchecked Sendable {
    let id = "down", displayName = "Down", keepsPlaceholders = true, usesContext = false, preferredBatchSize = 6
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func availability(source: String?, target: String) async -> EngineAvailability { .available }
    func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String] {
        lock.withLock { count += 1 }
        throw TranslationEngineError.transient("connection refused")
    }
}

private struct SlowEngine: TranslationEngine {
    let id = "slow", displayName = "Slow", keepsPlaceholders = true, usesContext = false, preferredBatchSize = 1
    func availability(source: String?, target: String) async -> EngineAvailability { .available }
    func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String] {
        try await Task.sleep(for: .milliseconds(100))
        return Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.text) })
    }
}

/// Real on-device translation. Runs only when English → Portuguese is downloaded on this Mac.
@Suite("Apple Translation (real, on-device)")
struct AppleTranslationIntegrationTests {
    @Test func translatesAnEpisodeKeepingMarkup() async throws {
        let status = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "pt-BR"))
        try #require(status == .installed, "en → pt-BR não está baixado neste Mac")
        let source = try episode()
        let (output, report) = try await TranslationPipeline(engine: AppleTranslationEngine(), options: .init(sourceLanguage: "en")).run(source)
        #expect(report.isComplete, "\(report.failedLines)")
        #expect(report.translatedLines == 6)
        #expect(StructureCheck.compare(source: source, translated: output).isValid)
        let tagged = output.rawText(at: 2)
        #expect(tagged.contains(#"{\i1}"#) && tagged.contains(#"{\i0}"#))
        #expect(output.rawText(at: 4).hasPrefix(#"{\an8\pos(960,120)\fad(200,200)\t(0,500,\fscx120)}"#))
        #expect(output.plainText(at: 1).lowercased().contains("amigos"))
    }
}

@Suite("Scale and continuity")
struct ScaleTests {
    @Test func previousEpisodeContextReachesTheFirstBatch() async throws {
        let engine = ScriptedEngine(batchSize: 3)
        let carried = [TranslationContext.PreviousLine(speaker: "Kirito", source: "See you tomorrow.", translation: "Até amanhã.")]
        _ = try await TranslationPipeline(engine: engine, options: .init(sourceLanguage: "en", contextLines: 4), carriedContext: carried).run(try episode())
        #expect(engine.allContexts[0].previousLines.first?.translation == "Até amanhã.")
    }

    @Test func handlesFiveThousandLines() async throws {
        var text = "[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        for i in 0..<5_000 {
            text += "Dialogue: 0,\(SubtitleTime.formatASS(i * 2_000)),\(SubtitleTime.formatASS(i * 2_000 + 1_500)),Default,Char\(i % 7),0,0,0,,Line {\\i1}\(i){\\i0}, with a comma\n"
        }
        let clock = ContinuousClock()
        let start = clock.now
        let source = SubtitleDocument.ass(ASSDocument.parse(text: text))
        #expect(source.serialized() == text)
        let (output, report) = try await TranslationPipeline(engine: ScriptedEngine(batchSize: 50), options: .init(sourceLanguage: "en")).run(source)
        let elapsed = clock.now - start
        #expect(report.translatedLines == 5_000 && report.isComplete)
        #expect(output.rawText(at: 4_999).contains(#"{\i1}4999{\i0}"#))
        #expect(elapsed < .seconds(20), "took \(elapsed)")
    }
}
