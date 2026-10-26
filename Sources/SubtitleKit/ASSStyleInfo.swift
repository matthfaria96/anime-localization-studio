import Foundation

/// An ASS color: `&HAABBGGRR` (alpha 00 = opaque). SSA files may store decimal integers.
public struct ASSColor: Sendable, Hashable {
    public var red: Double, green: Double, blue: Double
    /// 0 = transparent, 1 = opaque (ASS stores the inverse).
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let value: UInt32?
        if text.hasPrefix("&H") || text.hasPrefix("H") {
            text = String(text.drop { $0 == "&" || $0 == "H" }).trimmingCharacters(in: CharacterSet(charactersIn: "&"))
            value = UInt32(text, radix: 16)
        } else {
            value = Int64(text).map { UInt32(truncatingIfNeeded: $0) }
        }
        guard let v = value else { return nil }
        red = Double(v & 0xFF) / 255
        green = Double((v >> 8) & 0xFF) / 255
        blue = Double((v >> 16) & 0xFF) / 255
        opacity = 1 - Double((v >> 24) & 0xFF) / 255
    }

    /// `&H00BBGGRR` form, as Aegisub writes styles.
    public var assString: String {
        func byte(_ x: Double) -> String { String(format: "%02X", Int((min(1, max(0, x)) * 255).rounded())) }
        return "&H\(byte(1 - opacity))\(byte(blue))\(byte(green))\(byte(red))"
    }
}

/// Typed view of a `Style:` line, used by the preview renderer and the style editor.
public struct ASSStyleInfo: Sendable, Hashable {
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var primary: ASSColor
    public var outlineColor: ASSColor
    public var backColor: ASSColor
    public var bold: Bool
    public var italic: Bool
    public var outline: Double
    public var shadow: Double
    /// Numpad alignment (1–9), converted from SSA's legacy values when needed.
    public var alignment: Int
    public var marginL: Double, marginR: Double, marginV: Double

    public static let fallback = ASSStyleInfo(name: "Default", fontName: "Arial", fontSize: 20, primary: .init(red: 1, green: 1, blue: 1),
                                              outlineColor: .init(red: 0, green: 0, blue: 0), backColor: .init(red: 0, green: 0, blue: 0),
                                              bold: false, italic: false, outline: 2, shadow: 2, alignment: 2, marginL: 10, marginR: 10, marginV: 10)

    public init(name: String, fontName: String, fontSize: Double, primary: ASSColor, outlineColor: ASSColor, backColor: ASSColor,
                bold: Bool, italic: Bool, outline: Double, shadow: Double, alignment: Int, marginL: Double, marginR: Double, marginV: Double) {
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.primary = primary
        self.outlineColor = outlineColor
        self.backColor = backColor
        self.bold = bold
        self.italic = italic
        self.outline = outline
        self.shadow = shadow
        self.alignment = alignment
        self.marginL = marginL
        self.marginR = marginR
        self.marginV = marginV
    }

    public init(record: ASSRecord, isSSA: Bool) {
        let f = Self.fallback
        func text(_ key: String) -> String? { record[key]?.trimmingCharacters(in: .whitespaces) }
        func number(_ key: String) -> Double? { text(key).flatMap(Double.init) }
        func flag(_ key: String) -> Bool { (Int(text(key) ?? "0") ?? 0) != 0 }
        name = text("Name") ?? f.name
        fontName = text("Fontname") ?? f.fontName
        fontSize = number("Fontsize") ?? f.fontSize
        primary = text("PrimaryColour").flatMap(ASSColor.init) ?? f.primary
        outlineColor = (text("OutlineColour") ?? text("TertiaryColour")).flatMap(ASSColor.init) ?? f.outlineColor
        backColor = text("BackColour").flatMap(ASSColor.init) ?? f.backColor
        bold = flag("Bold")
        italic = flag("Italic")
        outline = number("Outline") ?? f.outline
        shadow = number("Shadow") ?? f.shadow
        let rawAlignment = Int(text("Alignment") ?? "") ?? 2
        alignment = isSSA ? Self.numpad(fromSSA: rawAlignment) : min(9, max(1, rawAlignment))
        marginL = number("MarginL") ?? f.marginL
        marginR = number("MarginR") ?? f.marginR
        marginV = number("MarginV") ?? f.marginV
    }

    /// SSA: 1–3 bottom, +4 top, +8 middle → numpad 1–9.
    public static func numpad(fromSSA value: Int) -> Int {
        let horizontal = ((value - 1) & 3) + 1
        if value & 4 != 0 { return horizontal + 6 }
        if value & 8 != 0 { return horizontal + 3 }
        return horizontal
    }

    /// Writes edited values back into a style record, field by field.
    public func apply(to record: inout ASSRecord) {
        func setIfChanged(_ key: String, _ value: String) {
            guard let current = record[key], current.trimmingCharacters(in: .whitespaces) != value else { return }
            record[key] = value
        }
        func number(_ x: Double) -> String { x.rounded() == x ? String(Int(x)) : String(x) }
        setIfChanged("Fontname", fontName)
        setIfChanged("Fontsize", number(fontSize))
        if let current = record["PrimaryColour"].flatMap(ASSColor.init), current != primary { record["PrimaryColour"] = primary.assString }
        if let current = record["OutlineColour"].flatMap(ASSColor.init), current != outlineColor { record["OutlineColour"] = outlineColor.assString }
        setIfChanged("Bold", bold ? "-1" : "0")
        setIfChanged("Italic", italic ? "-1" : "0")
        setIfChanged("Outline", number(outline))
        setIfChanged("Shadow", number(shadow))
        setIfChanged("Alignment", String(alignment))
        setIfChanged("MarginL", number(marginL))
        setIfChanged("MarginR", number(marginR))
        setIfChanged("MarginV", number(marginV))
    }
}
