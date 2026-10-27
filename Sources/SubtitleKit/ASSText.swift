import Foundation

/// The inline markup of an ASS `Text` field (or an SRT cue), split into tokens without losing
/// a single character: joining every token's `source` gives back the input.
public enum ASSTextToken: Sendable, Hashable {
    /// `{…}` including the braces: override tags (`{\an8\pos(640,50)}`) or a comment (`{TL note}`).
    case override(String)
    /// HTML-like SRT markup (`<i>`, `</font>`).
    case markup(String)
    case text(String)
    /// `\N` (hard) or `\n` (soft) line break, kept with its original spelling.
    case lineBreak(String)
    /// `\h`, a non-breaking space.
    case hardSpace

    public var source: String {
        switch self {
        case .override(let s), .markup(let s), .text(let s), .lineBreak(let s): return s
        case .hardSpace: return "\\h"
        }
    }
}

public enum ASSText {
    public static func tokenize(_ text: String, htmlMarkup: Bool = false) -> [ASSTextToken] {
        var tokens: [ASSTextToken] = []
        var buffer = ""
        var index = text.startIndex
        func flush() {
            if !buffer.isEmpty { tokens.append(.text(buffer)); buffer = "" }
        }
        while index < text.endIndex {
            let character = text[index]
            if character == "{", let close = text[index...].firstIndex(of: "}") {
                flush()
                tokens.append(.override(String(text[index...close])))
                index = text.index(after: close)
                continue
            }
            if htmlMarkup, character == "<", let close = text[index...].firstIndex(of: ">"),
               isHTMLTag(text[text.index(after: index)..<close]) {
                flush()
                tokens.append(.markup(String(text[index...close])))
                index = text.index(after: close)
                continue
            }
            if character == "\\", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex {
                switch text[next] {
                case "N", "n":
                    flush()
                    tokens.append(.lineBreak(String(text[index...next])))
                    index = text.index(after: next)
                    continue
                case "h":
                    flush()
                    tokens.append(.hardSpace)
                    index = text.index(after: next)
                    continue
                default: break
                }
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flush()
        return tokens
    }

    private static func isHTMLTag(_ inner: Substring) -> Bool {
        let name = inner.drop { $0 == "/" }.prefix { $0.isLetter }.lowercased()
        return ["i", "b", "u", "s", "font"].contains(name)
    }

    /// Text as a viewer reads it: tags and drawings removed, `\N` as a newline, `\h` as a space.
    /// A soft `\n` is a space unless the script uses wrap style 2, which the app does not model.
    public static func plainText(_ text: String, htmlMarkup: Bool = false) -> String {
        var output = ""
        var drawing = false
        for token in tokenize(text, htmlMarkup: htmlMarkup) {
            switch token {
            case .override(let block):
                if let level = drawingLevel(in: block) { drawing = level > 0 }
            case .markup: continue
            case .text(let s): if !drawing { output += s }
            case .lineBreak(let s): if !drawing { output += s == "\\N" ? "\n" : " " }
            case .hardSpace: if !drawing { output += "\u{00A0}" }
            }
        }
        return output
    }

    /// Facts about a line that decide how it may be translated and previewed.
    public struct Features: Sendable, Hashable {
        public var hasKaraoke = false
        public var hasDrawing = false
        public var hasAnimation = false
        public var hasPositioning = false
        public var hasInlineOverrides = false
        public var hasCommentBlocks = false
    }

    public static func features(of text: String) -> Features {
        var features = Features()
        let tokens = tokenize(text)
        var seenText = false
        for token in tokens {
            switch token {
            case .override(let block):
                let tags = tagNames(in: block)
                if tags.isEmpty { features.hasCommentBlocks = true }
                if tags.contains(where: { ["k", "K", "kf", "ko", "kt"].contains($0) }) { features.hasKaraoke = true }
                if (drawingLevel(in: block) ?? 0) > 0 { features.hasDrawing = true }
                if tags.contains(where: { ["t", "move", "fad", "fade"].contains($0) }) { features.hasAnimation = true }
                if tags.contains(where: { ["pos", "move", "org", "clip", "iclip"].contains($0) }) { features.hasPositioning = true }
                if seenText, !tags.isEmpty { features.hasInlineOverrides = true }
            case .text(let s): if !s.trimmingCharacters(in: .whitespaces).isEmpty { seenText = true }
            default: break
            }
        }
        return features
    }

    /// Tag names inside one `{…}` block, e.g. `{\an8\pos(1,2)\fs40}` → `an, pos, fs`.
    /// `\1c` style names keep their digit; numeric arguments are not part of the name.
    public static func tagNames(in block: String) -> [String] {
        var names: [String] = []
        var depth = 0
        let characters = Array(block)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if c == "\\", depth == 0 {
                var j = i + 1
                var name = ""
                if j < characters.count, characters[j].isNumber { name.append(characters[j]); j += 1 }
                while j < characters.count, characters[j].isLetter { name.append(characters[j]); j += 1 }
                if !name.isEmpty { names.append(normalizedTagName(name)) }
                i = j
                continue
            }
            i += 1
        }
        return names
    }

    /// libass reads the longest known name: `\fad` vs `\fade`, `\kf` vs `\k`, `\fscx` vs `\fs`…
    /// Arguments that start with letters (`\fnArial`, `\rSign`) are cut back to the tag name.
    private static func normalizedTagName(_ raw: String) -> String {
        let known = ["iclip", "clip", "fade", "fad", "move", "pos", "org", "fscx", "fscy", "fsp", "fs", "fn", "frx", "fry", "frz", "fr",
                     "fax", "fay", "fe", "bord", "xbord", "ybord", "shad", "xshad", "yshad", "blur", "be", "an", "a",
                     "kf", "ko", "kt", "k", "K", "alpha", "1a", "2a", "3a", "4a", "1c", "2c", "3c", "4c", "c", "i", "b", "u", "s",
                     "p", "pbo", "q", "r", "t"]
        for name in known.sorted(by: { $0.count > $1.count }) where raw.hasPrefix(name) {
            return name
        }
        return raw
    }

    /// The `\pN` value set by a block, if it sets one.
    static func drawingLevel(in block: String) -> Int? {
        guard let range = block.range(of: #"\\p(\d+)"#, options: .regularExpression) else { return nil }
        // `\pos` and `\pbo` also start with `\p`; only a digit right after `\p` is a drawing level.
        return Int(block[range].dropFirst(2))
    }

    /// The first `\anN` in the line (ASS numpad alignment), if any.
    public static func alignmentOverride(in text: String) -> Int? {
        guard let range = text.range(of: #"\\an([1-9])"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst(3))
    }

    /// The line with its position set to numpad `alignment` (`{\anN}`), or with every `\an`
    /// removed when nil (back to the style's position). Nothing else in the text changes.
    public static func settingAlignment(_ alignment: Int?, in text: String) -> String {
        var result = text.replacingOccurrences(of: #"\\an[1-9]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "{}", with: "")
        guard let alignment, (1...9).contains(alignment) else { return result }
        if result.hasPrefix("{") { return "{\\an\(alignment)" + result.dropFirst() }
        return "{\\an\(alignment)}" + result
    }

    /// The first `\pos(x,y)` in the line, if any.
    public static func positionOverride(in text: String) -> (x: Double, y: Double)? {
        guard let range = text.range(of: #"\\pos\(\s*-?[\d.]+\s*,\s*-?[\d.]+\s*\)"#, options: .regularExpression) else { return nil }
        let numbers = text[range].dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }
}
