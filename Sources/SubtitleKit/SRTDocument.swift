import Foundation

/// SubRip cue. The original lines are kept so an unedited cue is written back exactly.
public struct SRTCue: Sendable, Hashable {
    public var number: String
    public var start: Int
    public var end: Int
    /// Anything after the end time on the timing line (`X1:… Y1:…` positions).
    public var timingSuffix: String
    /// Cue text, lines separated by `\n`.
    public var text: String
    /// Who speaks. SubRip has no field for it, so it is never written to the file; the app
    /// keeps it in the project instead.
    public var speaker: String = ""
    fileprivate var trailingBlankLines: Int
    fileprivate let originalLines: [String]?
    fileprivate let originalSnapshot: Snapshot?

    fileprivate struct Snapshot: Sendable, Hashable {
        let number: String, start: Int, end: Int, timingSuffix: String, text: String
    }

    public init(number: String, start: Int, end: Int, text: String, timingSuffix: String = "") {
        self.number = number
        self.start = start
        self.end = end
        self.text = text
        self.timingSuffix = timingSuffix
        self.trailingBlankLines = 1
        self.originalLines = nil
        self.originalSnapshot = nil
    }

    fileprivate init(number: String, start: Int, end: Int, timingSuffix: String, text: String, trailingBlankLines: Int, originalLines: [String]) {
        self.number = number
        self.start = start
        self.end = end
        self.timingSuffix = timingSuffix
        self.text = text
        self.trailingBlankLines = trailingBlankLines
        self.originalLines = originalLines
        self.originalSnapshot = Snapshot(number: number, start: start, end: end, timingSuffix: timingSuffix, text: text)
    }

    public var isModified: Bool {
        originalSnapshot != Snapshot(number: number, start: start, end: end, timingSuffix: timingSuffix, text: text)
    }

    fileprivate func serializedLines() -> [String] {
        if let originalLines, !isModified { return originalLines }
        var lines = [number, "\(SubtitleTime.formatSRT(start)) --> \(SubtitleTime.formatSRT(end))\(timingSuffix)"]
        lines += text.components(separatedBy: "\n")
        lines += Array(repeating: "", count: trailingBlankLines)
        return lines
    }
}

public struct SRTDocument: Sendable, Hashable {
    public var preamble: [String]
    public var cues: [SRTCue]
    public var traits: TextFileTraits
    var pristine: PristineSource?

    public init(preamble: [String], cues: [SRTCue], traits: TextFileTraits) {
        self.preamble = preamble
        self.cues = cues
        self.traits = traits
    }

    public static func parse(_ data: Data) throws -> SRTDocument {
        let (text, traits) = try TextDecoder.decode(data)
        var document = parse(text: text, traits: traits)
        if !traits.repairedInvalidBytes { document.pristine = PristineSource(serialization: document.serialized(), data: data) }
        return document
    }

    public static func parse(text: String, traits: TextFileTraits = TextFileTraits()) -> SRTDocument {
        let lines = TextDecoder.lines(of: text)
        var headers: [Int] = []  // line index of each cue's timing line
        for (i, line) in lines.enumerated() where timing(of: line) != nil {
            headers.append(i)
        }
        // A cue starts at its number line when the line before the timing is a bare number.
        func startLine(ofHeader h: Int) -> Int {
            h > 0 && Int(lines[h - 1].trimmingCharacters(in: .whitespaces)) != nil ? h - 1 : h
        }
        let preambleEnd = headers.first.map(startLine(ofHeader:)) ?? lines.count
        var cues: [SRTCue] = []
        for (n, h) in headers.enumerated() {
            let begin = startLine(ofHeader: h)
            let end = n + 1 < headers.count ? startLine(ofHeader: headers[n + 1]) : lines.count
            let block = Array(lines[begin..<end])
            var textLines = Array(lines[(h + 1)..<end])
            var blanks = 0
            while let last = textLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.removeLast()
                blanks += 1
            }
            guard let (start, finish, suffix) = timing(of: lines[h]) else { continue }
            cues.append(SRTCue(
                number: begin < h ? lines[begin] : "",
                start: start, end: finish, timingSuffix: suffix,
                text: textLines.joined(separator: "\n"),
                trailingBlankLines: blanks, originalLines: block))
        }
        return SRTDocument(preamble: Array(lines[..<preambleEnd]), cues: cues, traits: traits)
    }

    static func timing(of line: String) -> (Int, Int, String)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound]
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endField = right.prefix { !$0.isWhitespace }
        guard let start = SubtitleTime.parseSRT(String(left)), let end = SubtitleTime.parseSRT(String(endField)) else { return nil }
        let suffixStart = line.range(of: String(endField), range: arrow.upperBound..<line.endIndex)?.upperBound ?? line.endIndex
        return (start, end, String(line[suffixStart...]))
    }

    public func serialized() -> String {
        var lines = preamble
        for cue in cues { lines += cue.serializedLines() }
        while lines.last == "" && !traits.endsWithNewline { lines.removeLast() }
        var output = lines.joined(separator: traits.newline)
        if traits.endsWithNewline, !lines.isEmpty { output += traits.newline }
        return output
    }

    public func encoded() -> Data {
        let text = serialized()
        if let pristine, pristine.serialization == text { return pristine.data }
        return TextDecoder.encode(text, traits: traits)
    }

    /// Renumbers cues 1…n (after inserting or removing).
    mutating func renumber() {
        for i in cues.indices where cues[i].number != String(i + 1) { cues[i].number = String(i + 1) }
    }
}
