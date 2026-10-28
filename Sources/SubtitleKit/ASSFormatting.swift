import Foundation

/// Formatting a line without typing tags: italic, bold, underline, strikeout, color and size
/// applied to a stretch of the text (or the whole line), cleared again, and read back as styled
/// runs for a preview. ASS uses override tags (`{\i1}…{\i0}`); SubRip its HTML-like markup
/// (`<i>…</i>`). Position, timing and animation tags are never touched.
public enum ASSFormatting {
    public enum Toggle: CaseIterable, Sendable {
        case italic, bold, underline, strikeout

        /// The ASS tag letter and the SubRip element: both are `i`, `b`, `u`, `s`.
        var letter: String {
            switch self {
            case .italic: "i"
            case .bold: "b"
            case .underline: "u"
            case .strikeout: "s"
            }
        }
    }

    /// A stretch of visible text and how it looks.
    public struct Run: Sendable, Hashable {
        public var text: String
        public var italic = false
        public var bold = false
        public var underline = false
        public var strikeout = false
        public var color: ASSColor?
    }

    // MARK: Applying

    /// Turns `kind` on for `range` (the whole line when nil), or off when that stretch already has it.
    public static func toggle(_ kind: Toggle, in text: String, range: Range<String.Index>?, html: Bool = false) -> String {
        let t = kind.letter
        if html {
            return wrapOrUnwrap(text, range: range, open: "<\(t)>", close: "</\(t)>", html: true)
        }
        guard let range else {
            let pattern = #"\\"# + t + #"1(?![0-9])"#
            if let block = leadingBlock(text), block.range(of: pattern, options: .regularExpression) != nil {
                let cleaned = block.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                return (cleaned == "{}" ? "" : cleaned) + text.dropFirst(block.count)
            }
            return addingToLeadingBlock("\\\(t)1", in: text)
        }
        return wrapOrUnwrap(text, range: range, open: "{\\\(t)1}", close: "{\\\(t)0}", html: false)
    }

    /// Colors `range` (the whole line when nil). After a stretch the color goes back to
    /// `restore` (the style's), or to the style's own when nil.
    public static func color(_ color: ASSColor, restore: ASSColor?, in text: String, range: Range<String.Index>?, html: Bool = false) -> String {
        if html {
            return wrapOrUnwrap(text, range: range, open: "<font color=\"#\(hex(color))\">", close: "</font>", html: true)
        }
        let tag = "\\1c\(inline(color))"
        guard let range else {
            let stripped = replacingInLeadingBlock(#"\\1?c(?![a-z])(&H[0-9A-Fa-f]+&?)?"#, in: text)
            return addingToLeadingBlock(tag, in: stripped)
        }
        return insert(open: "{\(tag)}", close: "{\\1c\(restore.map(inline) ?? "")}", in: text, range: range)
    }

    /// Sets the font size of `range` (the whole line when nil); after a stretch it goes back to `restore`.
    public static func size(_ size: Double, restore: Double, in text: String, range: Range<String.Index>?) -> String {
        let tag = "\\fs\(ASSText.number(size))"
        guard let range else {
            return addingToLeadingBlock(tag, in: replacingInLeadingBlock(#"\\fs[\d.]+"#, in: text))
        }
        return insert(open: "{\(tag)}", close: "{\\fs\(ASSText.number(restore))}", in: text, range: range)
    }

    /// Takes the look out of `range` (the whole line when nil): italic, bold, underline,
    /// strikeout, colors, transparency, size, font, outline, shadow and karaoke. Position,
    /// timing and animation tags stay.
    public static func clear(in text: String, range: Range<String.Index>?, html: Bool = false) -> String {
        let range = range.map { safe($0, in: text, html: html) } ?? text.startIndex..<text.endIndex
        let part = String(text[range])
        let cleaned: String
        if html {
            cleaned = part.replacingOccurrences(of: #"</?(?:i|b|u|s|font)(?:\s[^>]*)?>"#, with: "", options: [.regularExpression, .caseInsensitive])
        } else {
            let look = [#"\\[ibus][0-9]+"#, #"\\[1-4]?c(?![a-z])(?:&H[0-9A-Fa-f]+&?)?"#, #"\\(?:[1-4]a|alpha)&H[0-9A-Fa-f]+&?"#,
                        #"\\fs[0-9.]+"#, #"\\fn[^\\}]*"#, #"\\(?:bord|shad|blur|be|fscx|fscy|fsp)-?[0-9.]+"#,
                        #"\\(?:kf|ko|kt|k|K)[0-9]+"#].joined(separator: "|")
            cleaned = part.replacingOccurrences(of: look, with: "", options: .regularExpression).replacingOccurrences(of: "{}", with: "")
        }
        return text.replacingCharacters(in: range, with: cleaned)
    }

    // MARK: Reading

    /// The visible text in stretches of the same look, for a preview. Comments and drawings'
    /// code are not shown; `\N` becomes a line break.
    public static func runs(_ text: String, html: Bool = false) -> [Run] {
        var runs: [Run] = []
        var look = Run(text: "")
        func append(_ string: String) {
            guard !string.isEmpty else { return }
            if var last = runs.last, Run(text: "", italic: last.italic, bold: last.bold, underline: last.underline, strikeout: last.strikeout,
                                         color: last.color) == Run(text: "", italic: look.italic, bold: look.bold, underline: look.underline,
                                                                    strikeout: look.strikeout, color: look.color) {
                last.text += string
                runs[runs.count - 1] = last
            } else {
                var run = look
                run.text = string
                runs.append(run)
            }
        }
        for token in ASSText.tokenize(text, htmlMarkup: html) {
            switch token {
            case .text(let string): append(string)
            case .lineBreak(let spelling): append(spelling == "\\h" ? " " : "\n")
            case .hardSpace: append(" ")
            case .override(let block): apply(block, to: &look)
            case .markup(let tag): applyMarkup(tag, to: &look)
            }
        }
        return runs
    }

    private static func apply(_ block: String, to look: inout Run) {
        guard block.contains("\\") else { return }
        for part in block.dropFirst().dropLast().split(separator: "\\").map(String.init) {
            if let first = part.first, "ibus".contains(first), let value = Int(part.dropFirst()) {
                switch first {
                case "i": look.italic = value != 0
                case "b": look.bold = value != 0
                case "u": look.underline = value != 0
                default: look.strikeout = value != 0
                }
            } else if part.range(of: #"^1?c(&H[0-9A-Fa-f]+&?)?$"#, options: .regularExpression) != nil {
                let value = part.drop { $0 == "1" || $0 == "c" }
                look.color = value.isEmpty ? nil : ASSColor(String(value))
            } else if part.hasPrefix("r") {
                look = Run(text: "")
            }
        }
    }

    private static func applyMarkup(_ tag: String, to look: inout Run) {
        let lower = tag.lowercased()
        let closing = lower.hasPrefix("</")
        let name = lower.trimmingCharacters(in: CharacterSet(charactersIn: "</>")).split(separator: " ").first.map(String.init) ?? ""
        switch name {
        case "i": look.italic = !closing
        case "b": look.bold = !closing
        case "u": look.underline = !closing
        case "s": look.strikeout = !closing
        case "font":
            if closing { look.color = nil; return }
            guard let range = lower.range(of: #"#[0-9a-f]{6}"#, options: .regularExpression), let value = UInt32(lower[range].dropFirst(), radix: 16) else { return }
            look.color = ASSColor(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        default: break
        }
    }

    // MARK: Helpers

    /// `&HBBGGRR&`, the inline color spelling.
    static func inline(_ color: ASSColor) -> String {
        func byte(_ x: Double) -> String { String(format: "%02X", Int((min(1, max(0, x)) * 255).rounded())) }
        return "&H\(byte(color.blue))\(byte(color.green))\(byte(color.red))&"
    }

    /// `RRGGBB`, as HTML writes it.
    static func hex(_ color: ASSColor) -> String {
        func byte(_ x: Double) -> String { String(format: "%02X", Int((min(1, max(0, x)) * 255).rounded())) }
        return byte(color.red) + byte(color.green) + byte(color.blue)
    }

    /// The first `{…}` block when it holds override tags (not a comment).
    private static func leadingBlock(_ text: String) -> String? {
        if case .override(let block) = ASSText.tokenize(text).first, block.contains("\\") { return block }
        return nil
    }

    private static func addingToLeadingBlock(_ tag: String, in text: String) -> String {
        if let block = leadingBlock(text) { return String(block.dropLast()) + tag + "}" + text.dropFirst(block.count) }
        return "{\(tag)}" + text
    }

    private static func replacingInLeadingBlock(_ pattern: String, in text: String) -> String {
        guard let block = leadingBlock(text) else { return text }
        let cleaned = block.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return (cleaned == "{}" ? "" : cleaned) + text.dropFirst(block.count)
    }

    /// Unwraps when the stretch is already between `open` and `close` (inside or right around
    /// it); otherwise wraps it.
    private static func wrapOrUnwrap(_ text: String, range: Range<String.Index>?, open: String, close: String, html: Bool) -> String {
        let range = range.map { safe($0, in: text, html: html) } ?? text.startIndex..<text.endIndex
        let part = text[range]
        if part.hasPrefix(open), part.hasSuffix(close), part.count >= open.count + close.count {
            return text.replacingCharacters(in: range, with: part.dropFirst(open.count).dropLast(close.count))
        }
        if text[..<range.lowerBound].hasSuffix(open), text[range.upperBound...].hasPrefix(close) {
            let start = text.index(range.lowerBound, offsetBy: -open.count), end = text.index(range.upperBound, offsetBy: close.count)
            return text.replacingCharacters(in: start..<end, with: part)
        }
        return insert(open: open, close: close, in: text, range: range)
    }

    private static func insert(open: String, close: String, in text: String, range: Range<String.Index>) -> String {
        let range = safe(range, in: text, html: false)
        var result = text
        result.insert(contentsOf: close, at: range.upperBound)
        result.insert(contentsOf: open, at: range.lowerBound)
        return result
    }

    /// Moves the ends of a selection out of any `{…}` (or `<…>`) block they fall inside, so a
    /// tag is never cut in half.
    static func safe(_ range: Range<String.Index>, in text: String, html: Bool) -> Range<String.Index> {
        let (open, close): (Character, Character) = html ? ("<", ">") : ("{", "}")
        func outside(_ index: String.Index) -> String.Index {
            guard let opening = text[..<index].lastIndex(of: open) else { return index }
            if let closing = text[opening..<index].firstIndex(of: close), closing < index { return index }
            return text[index...].firstIndex(of: close).map { text.index(after: $0) } ?? index
        }
        let lower = outside(range.lowerBound), upper = max(lower, outside(range.upperBound))
        return lower..<upper
    }
}
