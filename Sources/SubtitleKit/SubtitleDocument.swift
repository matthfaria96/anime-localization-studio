import Foundation

public enum SubtitleFormat: String, Sendable, Codable, CaseIterable {
    case ass, ssa, srt

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "ass": self = .ass
        case "ssa": self = .ssa
        case "srt": self = .srt
        default: return nil
        }
    }

    /// Matroska codec ids (`S_TEXT/ASS`, `S_TEXT/UTF8`…) and FFmpeg codec names.
    public init?(codec: String) {
        switch codec.lowercased() {
        case "s_text/ass", "ass", "substation alpha", "advanced substation alpha": self = .ass
        case "s_text/ssa", "ssa": self = .ssa
        case "s_text/utf8", "subrip", "srt", "subrip/srt": self = .srt
        default: return nil
        }
    }

    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .ass: "ASS"
        case .ssa: "SSA"
        case .srt: "SRT"
        }
    }
}

/// What the editor shows for one line of any format.
public struct SubtitleCue: Sendable, Hashable, Identifiable {
    public let id: Int
    public var start: Int
    public var end: Int
    public var style: String
    public var actor: String
    public var effect: String
    public var layer: Int
    public var rawText: String
    public var isComment: Bool
    public var features: ASSText.Features
    public var usesHTMLMarkup: Bool

    public var plainText: String { ASSText.plainText(rawText, htmlMarkup: usesHTMLMarkup) }
    public var duration: Int { max(0, end - start) }
}

/// Why a line is not sent for translation.
public enum TranslationSkipReason: String, Sendable, Codable, CaseIterable {
    case comment, karaoke, drawing, noText, nonDialogue

    public var label: String {
        switch self {
        case .comment: "Comentário"
        case .karaoke: "Karaokê"
        case .drawing: "Desenho vetorial"
        case .noText: "Sem texto"
        case .nonDialogue: "Evento não textual"
        }
    }
}

public enum SubtitleDocument: Sendable, Hashable {
    case ass(ASSDocument)
    case srt(SRTDocument)

    public static func parse(_ data: Data, format: SubtitleFormat) throws -> SubtitleDocument {
        switch format {
        case .ass, .ssa: return .ass(try ASSDocument.parse(data))
        case .srt: return .srt(try SRTDocument.parse(data))
        }
    }

    public static func load(_ url: URL) throws -> SubtitleDocument {
        guard let format = SubtitleFormat(fileExtension: url.pathExtension) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try parse(try Data(contentsOf: url), format: format)
    }

    public var format: SubtitleFormat {
        switch self {
        case .ass(let doc): doc.isSSA ? .ssa : .ass
        case .srt: .srt
        }
    }

    public var usesHTMLMarkup: Bool { if case .srt = self { true } else { false } }

    public var count: Int {
        switch self {
        case .ass(let doc): doc.eventCount
        case .srt(let doc): doc.cues.count
        }
    }

    public var cues: [SubtitleCue] {
        switch self {
        case .ass(let doc):
            return doc.events.enumerated().map { i, e in
                SubtitleCue(id: i, start: e.start, end: e.end, style: e.styleName, actor: e.actor, effect: e.effect,
                            layer: e.layer, rawText: e.text, isComment: !e.isDialogue, features: ASSText.features(of: e.text), usesHTMLMarkup: false)
            }
        case .srt(let doc):
            return doc.cues.enumerated().map { i, c in
                SubtitleCue(id: i, start: c.start, end: c.end, style: "", actor: c.speaker, effect: "", layer: 0,
                            rawText: c.text, isComment: false, features: ASSText.features(of: c.text), usesHTMLMarkup: true)
            }
        }
    }

    public func rawText(at index: Int) -> String {
        switch self {
        case .ass(let doc): doc.event(at: index).text
        case .srt(let doc): doc.cues[index].text
        }
    }

    public func plainText(at index: Int) -> String {
        ASSText.plainText(rawText(at: index), htmlMarkup: usesHTMLMarkup)
    }

    // MARK: Editing

    public mutating func setRawText(_ text: String, at index: Int) {
        switch self {
        case .ass(var doc):
            // Real newlines typed in the editor are ASS hard breaks.
            let value = text.replacingOccurrences(of: "\r\n", with: "\\N").replacingOccurrences(of: "\n", with: "\\N")
            doc.updateEvent(at: index) { $0.text = value }
            self = .ass(doc)
        case .srt(var doc):
            // A blank line inside a cue would end it; keep line breaks, drop empty lines.
            doc.cues[index].text = text.replacingLineTerminators(with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: true).joined(separator: "\n")
            self = .srt(doc)
        }
    }

    public mutating func setTiming(start: Int, end: Int, at index: Int) {
        let start = max(0, start)
        let end = max(start, end)
        switch self {
        case .ass(var doc):
            doc.updateEvent(at: index) { record in
                // Writing an unchanged value would still reformat it; only touch what moved.
                if record.start != start { record.start = start }
                if record.end != end { record.end = end }
            }
            self = .ass(doc)
        case .srt(var doc):
            doc.cues[index].start = start
            doc.cues[index].end = end
            self = .srt(doc)
        }
    }

    /// Adds an empty line right after `index`, filling the gap to the next line (or 2 s).
    @discardableResult
    public mutating func insertLine(after index: Int) -> Int {
        let all = cues
        let start = all[index].end
        let next = all.indices.contains(index + 1) ? all[index + 1].start : start + 2_000
        let end = next > start + 300 ? next : start + 2_000
        switch self {
        case .ass(var doc):
            let new = doc.insertEvent(after: index, start: start, end: end)
            self = .ass(doc)
            return new
        case .srt(var doc):
            doc.cues.insert(SRTCue(number: "", start: start, end: end, text: ""), at: index + 1)
            doc.renumber()
            self = .srt(doc)
            return index + 1
        }
    }

    public mutating func removeLine(at index: Int) {
        switch self {
        case .ass(var doc):
            doc.removeEvent(at: index)
            self = .ass(doc)
        case .srt(var doc):
            doc.cues.remove(at: index)
            doc.renumber()
            self = .srt(doc)
        }
    }

    public mutating func setActor(_ actor: String, at index: Int) {
        switch self {
        case .ass(var doc):
            doc.updateEvent(at: index) { $0.actor = actor }
            self = .ass(doc)
        case .srt(var doc):
            guard doc.cues.indices.contains(index) else { return }
            doc.cues[index].speaker = actor
            self = .srt(doc)
        }
    }

    /// Whether the character of each line is stored in the file (ASS `Name`) or only in the app (SRT).
    public var storesActorsInFile: Bool { if case .ass = self { true } else { false } }

    /// Characters of a SubRip document by line, to keep outside the file.
    public var sideSpeakers: [Int: String] {
        guard case .srt(let doc) = self else { return [:] }
        return Dictionary(uniqueKeysWithValues: doc.cues.enumerated().compactMap { $1.speaker.isEmpty ? nil : ($0, $1.speaker) })
    }

    /// The same document with characters kept outside the file put in: every SubRip line, and
    /// ASS lines whose own `Name` is empty (a name written in the file always wins).
    public func withSideSpeakers(_ speakers: [Int: String]) -> SubtitleDocument {
        guard !speakers.isEmpty else { return self }
        switch self {
        case .srt(var doc):
            for (index, name) in speakers where doc.cues.indices.contains(index) { doc.cues[index].speaker = name }
            return .srt(doc)
        case .ass(var doc):
            for (index, name) in speakers where index < doc.eventCount && doc.event(at: index).actor.isEmpty {
                doc.updateEvent(at: index) { $0.actor = name }
            }
            return .ass(doc)
        }
    }

    public mutating func setStyle(_ style: String, at index: Int) {
        guard case .ass(var doc) = self else { return }
        doc.updateEvent(at: index) { $0.styleName = style }
        self = .ass(doc)
    }

    /// Moves the given lines (all when `indices` is nil) by `offset` milliseconds.
    public mutating func shift(by offset: Int, indices: Set<Int>? = nil) {
        let all = cues
        for cue in all where indices?.contains(cue.id) ?? true {
            setTiming(start: cue.start + offset, end: cue.end + offset, at: cue.id)
        }
    }

    // MARK: Find and replace (visible text only, never inside tags)

    /// Indices whose visible text contains `query`.
    public func find(_ query: String, caseSensitive: Bool = false) -> [Int] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        return (0..<count).filter { plainText(at: $0).range(of: query, options: options) != nil }
    }

    /// Replaces inside text tokens only, so tags such as `{\fnArial}` are never altered.
    /// Returns how many lines changed.
    @discardableResult
    public mutating func replace(_ query: String, with replacement: String, caseSensitive: Bool = false, indices: Set<Int>? = nil) -> Int {
        guard !query.isEmpty else { return 0 }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var changed = 0
        for index in 0..<count where indices?.contains(index) ?? true {
            let original = rawText(at: index)
            let tokens = ASSText.tokenize(original, htmlMarkup: usesHTMLMarkup)
            let rebuilt = tokens.map { token -> String in
                guard case .text(let s) = token else { return token.source }
                return s.replacingOccurrences(of: query, with: replacement, options: options)
            }.joined()
            if rebuilt != original {
                setRawText(rebuilt, at: index)
                changed += 1
            }
        }
        return changed
    }

    // MARK: Translation support

    /// Why line `index` should be left untranslated, or `nil` when it should be translated.
    public func skipReason(at index: Int, translateKaraoke: Bool = false) -> TranslationSkipReason? {
        if case .ass(let doc) = self {
            let event = doc.event(at: index)
            if event.isComment { return .comment }
            if !event.isDialogue { return .nonDialogue }
        }
        let features = ASSText.features(of: rawText(at: index))
        if features.hasDrawing { return .drawing }
        if features.hasKaraoke && !translateKaraoke { return .karaoke }
        if TranslatableText(rawText: rawText(at: index), htmlMarkup: usesHTMLMarkup) == nil { return .noText }
        return nil
    }

    public func translatable(at index: Int) -> TranslatableText? {
        TranslatableText(rawText: rawText(at: index), htmlMarkup: usesHTMLMarkup)
    }

    // MARK: Output

    public func serialized() -> String {
        switch self {
        case .ass(let doc): doc.serialized()
        case .srt(let doc): doc.serialized()
        }
    }

    public func encoded() -> Data {
        switch self {
        case .ass(let doc): doc.encoded()
        case .srt(let doc): doc.encoded()
        }
    }

    /// Writes through a temporary file and an atomic rename, so a crash never leaves half a file.
    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
