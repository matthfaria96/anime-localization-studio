import Foundation

/// One `Style:` or event (`Dialogue:`, `Comment:`, …) line split into its `Format:` fields.
///
/// The last field (`Text` for events) keeps every comma it contains. Values are stored raw, so a
/// margin written as `0000` or a time written as `0:00:01.00` comes back the same. The original
/// line is kept: while no field changes, `serialized()` returns it unchanged.
public struct ASSRecord: Sendable, Hashable {
    static let eventKinds: Set<String> = ["dialogue", "comment", "picture", "sound", "movie", "command"]
    static let defaultEventFormat = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
    static let defaultSSAEventFormat = ["Marked", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
    static let defaultStyleFormat = [
        "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour", "OutlineColour", "BackColour",
        "Bold", "Italic", "Underline", "StrikeOut", "ScaleX", "ScaleY", "Spacing", "Angle", "BorderStyle",
        "Outline", "Shadow", "Alignment", "MarginL", "MarginR", "MarginV", "Encoding"
    ]
    static let defaultSSAStyleFormat = [
        "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour", "TertiaryColour", "BackColour",
        "Bold", "Italic", "BorderStyle", "Outline", "Shadow", "Alignment", "MarginL", "MarginR", "MarginV",
        "AlphaLevel", "Encoding"
    ]

    public var kind: String
    public private(set) var format: [String]
    public private(set) var fields: [String]
    private let original: Original?

    private struct Original: Sendable, Hashable {
        let line: String
        let kind: String
        let fields: [String]
        /// Text between `Kind:` and the first field (usually one space), kept for rewrites.
        let leading: String
    }

    init(kind: String, rawLine: String, valueStart value: String, format: [String]) {
        let leading = String(value.prefix { $0 == " " || $0 == "\t" })
        let body = value.dropFirst(leading.count)
        let fieldCount = max(1, format.count)
        var split = body.split(separator: ",", maxSplits: fieldCount - 1, omittingEmptySubsequences: false).map(String.init)
        // A short line (fewer commas than the format) still keeps every field addressable.
        while split.count < fieldCount { split.append("") }
        self.kind = kind
        self.format = format
        self.fields = split
        self.original = Original(line: rawLine, kind: kind, fields: split, leading: leading)
    }

    public init(kind: String, format: [String], fields: [String]) {
        self.kind = kind
        self.format = format
        self.fields = fields + Array(repeating: "", count: max(0, format.count - fields.count))
        self.original = nil
    }

    /// The same values, written fresh on save (used for inserted lines).
    func detachedCopy() -> ASSRecord {
        ASSRecord(kind: kind, format: format, fields: fields)
    }

    public var isModified: Bool {
        guard let original else { return true }
        return original.kind != kind || original.fields != fields
    }

    public func serialized() -> String {
        if let original, !isModified { return original.line }
        return "\(kind):\(original?.leading ?? " ")\(fields.joined(separator: ","))"
    }

    // MARK: Field access by `Format:` name (case-insensitive, like libass)

    public func index(of name: String) -> Int? {
        format.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public subscript(name: String) -> String? {
        get { index(of: name).map { fields[$0] } }
        set {
            guard let i = index(of: name), var value = newValue else { return }
            // A line terminator would split the record into two lines of the file.
            let isLast = i == fields.count - 1
            value = value.replacingLineTerminators(with: isLast ? "\\N" : " ")
            // Commas would shift every following field; only the last field may contain them.
            fields[i] = isLast ? value : value.replacingOccurrences(of: ",", with: ";")
        }
    }

    // MARK: Event conveniences

    public var isComment: Bool { kind.caseInsensitiveCompare("Comment") == .orderedSame }
    public var isDialogue: Bool { kind.caseInsensitiveCompare("Dialogue") == .orderedSame }

    public var text: String {
        get { self["Text"] ?? "" }
        set { self["Text"] = newValue }
    }

    public var start: Int {
        get { self["Start"].flatMap(SubtitleTime.parseASS) ?? 0 }
        set { self["Start"] = SubtitleTime.formatASS(newValue) }
    }

    public var end: Int {
        get { self["End"].flatMap(SubtitleTime.parseASS) ?? 0 }
        set { self["End"] = SubtitleTime.formatASS(newValue) }
    }

    public var styleName: String {
        get { self["Style"]?.trimmingCharacters(in: .whitespaces) ?? "" }
        set { self["Style"] = newValue }
    }

    public var actor: String {
        get { (self["Name"] ?? self["Actor"])?.trimmingCharacters(in: .whitespaces) ?? "" }
        set { if index(of: "Name") != nil { self["Name"] = newValue } else { self["Actor"] = newValue } }
    }

    public var effect: String { self["Effect"]?.trimmingCharacters(in: .whitespaces) ?? "" }
    public var layer: Int { Int(self["Layer"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0 }
}
