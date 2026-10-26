import Foundation

/// A field-preserving ASS/SSA document.
///
/// The parser keeps every line of the file in order. Lines the app does not understand or never
/// edits (script info, comments, `[Fonts]`, `[Graphics]`, Aegisub project data, unknown sections)
/// are written back verbatim. Style and event lines are split into their `Format:` fields; a line
/// whose fields were not changed is also written back exactly as read, so an untouched document
/// round-trips byte for byte.
public struct ASSDocument: Sendable, Hashable {
    public enum Line: Sendable, Hashable {
        /// Anything kept verbatim: blank lines, `;` comments, `Key: value` pairs, embedded fonts.
        case raw(String)
        case section(name: String, raw: String)
        case format(section: String, fields: [String], raw: String)
        case style(ASSRecord)
        case event(ASSRecord)
    }

    public private(set) var lines: [Line]
    public var traits: TextFileTraits
    /// `true` for `[V4 Styles]` (SSA), which uses a different alignment numbering.
    public private(set) var isSSA: Bool
    private var eventLineIndices: [Int]
    private var styleLineIndices: [Int]

    public init(lines: [Line], traits: TextFileTraits) {
        self.lines = lines
        self.traits = traits
        self.isSSA = false
        self.eventLineIndices = []
        self.styleLineIndices = []
        reindex()
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> ASSDocument {
        let (text, traits) = try TextDecoder.decode(data)
        return parse(text: text, traits: traits)
    }

    public static func parse(text: String, traits: TextFileTraits = TextFileTraits()) -> ASSDocument {
        var lines: [Line] = []
        var section = ""
        var styleFormat = ASSRecord.defaultStyleFormat
        var eventFormat = ASSRecord.defaultEventFormat
        for rawLine in TextDecoder.lines(of: text) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast()).lowercased()
                if section == "v4 styles" {
                    styleFormat = ASSRecord.defaultSSAStyleFormat
                    eventFormat = ASSRecord.defaultSSAEventFormat
                }
                lines.append(.section(name: section, raw: rawLine))
                continue
            }
            guard let colon = rawLine.firstIndex(of: ":"), !trimmed.hasPrefix(";") else {
                lines.append(.raw(rawLine))
                continue
            }
            let key = rawLine[..<colon].trimmingCharacters(in: .whitespaces)
            let value = String(rawLine[rawLine.index(after: colon)...])
            let isStyleSection = section == "v4+ styles" || section == "v4 styles" || section == "v4++ styles"
            let isEventSection = section == "events"
            if (isStyleSection || isEventSection), key.caseInsensitiveCompare("Format") == .orderedSame {
                let fields = value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if isStyleSection { styleFormat = fields } else { eventFormat = fields }
                lines.append(.format(section: section, fields: fields, raw: rawLine))
            } else if isStyleSection, key.caseInsensitiveCompare("Style") == .orderedSame {
                lines.append(.style(ASSRecord(kind: key, rawLine: rawLine, valueStart: value, format: styleFormat)))
            } else if isEventSection, ASSRecord.eventKinds.contains(key.lowercased()) {
                lines.append(.event(ASSRecord(kind: key, rawLine: rawLine, valueStart: value, format: eventFormat)))
            } else {
                lines.append(.raw(rawLine))
            }
        }
        return ASSDocument(lines: lines, traits: traits)
    }

    // MARK: Serialization

    public func serialized() -> String {
        var output = lines.map { line -> String in
            switch line {
            case .raw(let raw), .section(_, let raw), .format(_, _, let raw): return raw
            case .style(let record), .event(let record): return record.serialized()
            }
        }.joined(separator: traits.newline)
        if traits.endsWithNewline, !lines.isEmpty { output += traits.newline }
        return output
    }

    public func encoded() -> Data {
        TextDecoder.encode(serialized(), traits: traits)
    }

    // MARK: Access

    public var eventCount: Int { eventLineIndices.count }
    public var styleCount: Int { styleLineIndices.count }

    public var events: [ASSRecord] {
        eventLineIndices.compactMap { if case .event(let r) = lines[$0] { r } else { nil } }
    }

    public var styles: [ASSRecord] {
        styleLineIndices.compactMap { if case .style(let r) = lines[$0] { r } else { nil } }
    }

    public func event(at index: Int) -> ASSRecord {
        guard case .event(let record) = lines[eventLineIndices[index]] else { preconditionFailure("index map out of sync") }
        return record
    }

    public mutating func updateEvent(at index: Int, _ change: (inout ASSRecord) -> Void) {
        var record = event(at: index)
        change(&record)
        lines[eventLineIndices[index]] = .event(record)
    }

    public func style(named name: String) -> ASSRecord? {
        // libass falls back to the first style named "Default" (case-insensitive) when absent.
        styles.last { $0["Name"]?.caseInsensitiveCompare(name) == .orderedSame }
            ?? styles.first { $0["Name"]?.caseInsensitiveCompare("Default") == .orderedSame }
    }

    public mutating func updateStyle(at index: Int, _ change: (inout ASSRecord) -> Void) {
        guard case .style(var record) = lines[styleLineIndices[index]] else { return }
        change(&record)
        lines[styleLineIndices[index]] = .style(record)
    }

    /// Inserts a copy of an event right after it and returns the new event's index.
    @discardableResult
    public mutating func duplicateEvent(at index: Int) -> Int {
        let record = event(at: index).detachedCopy()
        lines.insert(.event(record), at: eventLineIndices[index] + 1)
        reindex()
        return index + 1
    }

    public mutating func removeEvent(at index: Int) {
        lines.remove(at: eventLineIndices[index])
        reindex()
    }

    /// `[Script Info]` values such as `PlayResX`, `Title` or `ScriptType`.
    public func scriptInfo(_ key: String) -> String? {
        var inInfo = false
        for line in lines {
            switch line {
            case .section(let name, _): inInfo = name == "script info"
            case .raw(let raw) where inInfo:
                guard let colon = raw.firstIndex(of: ":"), !raw.hasPrefix(";") else { continue }
                if raw[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                    return raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            default: continue
            }
        }
        return nil
    }

    /// Reference resolution libass uses for positioning. Defaults follow libass when only one
    /// side is present (4:3 for missing width, 384×288 when both are missing).
    public var playResolution: (width: Double, height: Double) {
        let x = scriptInfo("PlayResX").flatMap(Double.init)
        let y = scriptInfo("PlayResY").flatMap(Double.init)
        switch (x, y) {
        case let (x?, y?) where x > 0 && y > 0: return (x, y)
        case let (x?, nil) where x > 0: return (x, x == 1280 ? 1024 : x * 3 / 4)
        case let (nil, y?) where y > 0: return (y == 1024 ? 1280 : y * 4 / 3, y)
        default: return (384, 288)
        }
    }

    /// Names of fonts embedded in `[Fonts]` (`fontname: name.ttf`).
    public var embeddedFontNames: [String] {
        var inFonts = false
        var names: [String] = []
        for line in lines {
            switch line {
            case .section(let name, _): inFonts = name == "fonts"
            case .raw(let raw) where inFonts && raw.lowercased().hasPrefix("fontname:"):
                names.append(raw.dropFirst("fontname:".count).trimmingCharacters(in: .whitespaces))
            default: continue
            }
        }
        return names
    }

    private mutating func reindex() {
        eventLineIndices = []
        styleLineIndices = []
        isSSA = false
        for (offset, line) in lines.enumerated() {
            switch line {
            case .event: eventLineIndices.append(offset)
            case .style: styleLineIndices.append(offset)
            case .section(let name, _) where name == "v4 styles": isSSA = true
            default: break
            }
        }
    }
}
