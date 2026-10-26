import Foundation

/// The translatable part of one subtitle line, with its markup taken out and put back safely.
///
/// Leading and trailing tag blocks (`{\an8\pos(…)}`, `<i>`) never reach a translator. Tags in the
/// middle of the line become numbered placeholders (`⟦1⟧`), which a translation must return
/// exactly once each; when it does not, `segments` allows translating the pieces between the
/// tags one by one instead, which keeps the markup at the cost of sentence context.
public struct TranslatableText: Sendable, Hashable, Codable {
    public let prefix: String
    public let suffix: String
    /// Text sent to the translator: inner tags as `⟦n⟧`, line breaks as spaces.
    public let body: String
    public let placeholders: [String]
    /// The pieces of plain text between inner tags, for the segment-by-segment fallback.
    public let segments: [String]
    public let lineBreakCount: Int
    /// `"\\N"` for ASS, `"\n"` for SRT.
    public let breakToken: String

    public enum RebuildError: Error, Equatable, LocalizedError {
        case placeholderMismatch(expected: Int, found: [Int])
        case segmentCountMismatch

        public var errorDescription: String? {
            switch self {
            case .placeholderMismatch: return "A tradução não devolveu as marcações de formatação da fala."
            case .segmentCountMismatch: return "A tradução por partes devolveu um número de partes diferente do original."
            }
        }
    }

    public static func placeholder(_ number: Int) -> String { "⟦\(number)⟧" }

    /// Returns `nil` when the line has nothing to translate (only tags, spaces or punctuation-free blanks).
    public init?(rawText: String, htmlMarkup: Bool = false) {
        breakToken = htmlMarkup ? "\n" : "\\N"
        var tokens = ASSText.tokenize(rawText, htmlMarkup: htmlMarkup)
        if htmlMarkup { tokens = Self.splitNewlines(tokens) }
        tokens = Self.markDrawings(tokens)
        let isTag: (ASSTextToken) -> Bool = {
            switch $0 { case .override, .markup: return true; default: return false }
        }
        let firstText = tokens.firstIndex { !isTag($0) } ?? tokens.endIndex
        let lastText = tokens.lastIndex { !isTag($0) } ?? -1
        guard firstText <= lastText else { return nil }
        prefix = tokens[..<firstText].map(\.source).joined()
        suffix = tokens[(lastText + 1)...].map(\.source).joined()

        var body = ""
        var placeholders: [String] = []
        var segments: [String] = [""]
        var breaks = 0
        for token in tokens[firstText...lastText] {
            switch token {
            case .override(let s), .markup(let s):
                placeholders.append(s)
                body += Self.placeholder(placeholders.count)
                segments.append("")
            case .text(let s):
                body += s
                segments[segments.count - 1] += s
            case .lineBreak:
                breaks += 1
                body += " "
                segments[segments.count - 1] += " "
            case .hardSpace:
                body += "\u{00A0}"
                segments[segments.count - 1] += "\u{00A0}"
            }
        }
        guard body.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        self.body = body
        self.placeholders = placeholders
        self.segments = segments
        self.lineBreakCount = breaks
    }

    /// Puts a whole-line translation back together with the original markup.
    public func rebuild(translation: String) throws(RebuildError) -> String {
        var text = Self.sanitize(translation, breakToken: breakToken)
        var found: [Int] = []
        let pattern = /⟦(\d+)⟧/
        for match in text.matches(of: pattern) { if let n = Int(match.1) { found.append(n) } }
        let expected = placeholders.isEmpty ? [] : Array(1...placeholders.count)
        guard found.sorted() == expected else {
            throw .placeholderMismatch(expected: placeholders.count, found: found)
        }
        text = rebalance(text)
        for (offset, tag) in placeholders.enumerated().reversed() {
            text = text.replacingOccurrences(of: Self.placeholder(offset + 1), with: tag)
        }
        return prefix + text + suffix
    }

    /// Puts segment-by-segment translations back between the original inner tags.
    public func rebuild(segments translated: [String]) throws(RebuildError) -> String {
        guard translated.count == segments.count else { throw .segmentCountMismatch }
        var text = ""
        for (offset, piece) in translated.enumerated() {
            let original = segments[offset]
            // Keep the spacing around tags that the original had; translators trim it.
            let lead = String(original.prefix { $0 == " " })
            let trail = String(original.reversed().prefix { $0 == " " })
            let core = piece.trimmingCharacters(in: .whitespaces)
            text += original.trimmingCharacters(in: .whitespaces).isEmpty ? original : lead + Self.sanitize(core, breakToken: breakToken) + trail
            if offset < placeholders.count { text += Self.placeholder(offset + 1) }
        }
        text = rebalance(text)
        for (offset, tag) in placeholders.enumerated().reversed() {
            text = text.replacingOccurrences(of: Self.placeholder(offset + 1), with: tag)
        }
        return prefix + text + suffix
    }

    /// Plain-text characters that would turn into markup are neutralized; newlines become breaks.
    static func sanitize(_ translation: String, breakToken: String) -> String {
        var text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingLineTerminators(with: "\n")
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        if breakToken == "\\N" {
            text = text.replacingOccurrences(of: "\\", with: "＼")
            text = text.replacingOccurrences(of: "\u{00A0}", with: "\\h")
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: breakToken)
    }

    /// When the source had a line break and the translation has none, break the translation
    /// once, at the space closest to the middle of its visible text.
    func rebalance(_ text: String) -> String {
        guard lineBreakCount > 0, !text.contains(breakToken) else { return text }
        let visible = text.replacing(/⟦\d+⟧/, with: "")
        guard visible.count >= 16 else { return text }
        let characters = Array(text)
        var visibleOffset = 0
        var inPlaceholder = false
        var best: (index: Int, distance: Int)?
        let middle = visible.count / 2
        for (i, c) in characters.enumerated() {
            if c == "⟦" { inPlaceholder = true }
            if !inPlaceholder {
                if c == " " {
                    let distance = abs(visibleOffset - middle)
                    if best == nil || distance < best!.distance { best = (i, distance) }
                }
                visibleOffset += 1
            }
            if c == "⟧" { inPlaceholder = false }
        }
        guard let split = best else { return text }
        return String(characters[..<split.index]) + breakToken + String(characters[(split.index + 1)...])
    }

    /// Text drawn in `\p1` mode is vector commands (`m 0 0 l 10 0`), kept like a tag.
    private static func markDrawings(_ tokens: [ASSTextToken]) -> [ASSTextToken] {
        var drawing = false
        return tokens.map { token in
            switch token {
            case .override(let block):
                if let level = ASSText.drawingLevel(in: block) { drawing = level > 0 }
                return token
            case .text(let s) where drawing: return .override(s)
            default: return token
            }
        }
    }

    private static func splitNewlines(_ tokens: [ASSTextToken]) -> [ASSTextToken] {
        tokens.flatMap { token -> [ASSTextToken] in
            guard case .text(let s) = token, s.contains("\n") else { return [token] }
            var result: [ASSTextToken] = []
            for (i, part) in s.components(separatedBy: "\n").enumerated() {
                if i > 0 { result.append(.lineBreak("\n")) }
                if !part.isEmpty { result.append(.text(part)) }
            }
            return result
        }
    }
}
