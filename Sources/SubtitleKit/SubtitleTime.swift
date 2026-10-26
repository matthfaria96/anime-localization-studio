import Foundation

/// Subtitle timestamps in milliseconds, with the two textual forms the app reads and writes.
/// ASS/SSA store centiseconds (`H:MM:SS.cc`); SRT stores milliseconds (`HH:MM:SS,mmm`).
public enum SubtitleTime {
    /// Parses `H:MM:SS.cc` (ASS/SSA). Accepts 1–3 fractional digits and surrounding spaces.
    public static func parseASS(_ raw: String) -> Int? {
        parse(raw, fractionSeparators: [".", ","])
    }

    /// Parses `HH:MM:SS,mmm` (SRT). Accepts `.` as separator, which real-world files use too.
    public static func parseSRT(_ raw: String) -> Int? {
        parse(raw, fractionSeparators: [",", "."])
    }

    /// `H:MM:SS.cc`, rounded to the nearest centisecond, as libass and Aegisub write it.
    public static func formatASS(_ milliseconds: Int) -> String {
        let cs = (max(0, milliseconds) + 5) / 10
        let h = cs / 360_000
        let m = (cs / 6_000) % 60
        let s = (cs / 100) % 60
        let c = cs % 100
        return "\(h):\(pad(m, 2)):\(pad(s, 2)).\(pad(c, 2))"
    }

    /// `HH:MM:SS,mmm`.
    public static func formatSRT(_ milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        let h = ms / 3_600_000
        let m = (ms / 60_000) % 60
        let s = (ms / 1_000) % 60
        return "\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2)),\(pad(ms % 1_000, 3))"
    }

    /// Compact display form for the editor (`M:SS.cc`, or `H:MM:SS.cc` past an hour).
    public static func formatDisplay(_ milliseconds: Int) -> String {
        let cs = max(0, milliseconds) / 10
        let h = cs / 360_000
        let m = (cs / 6_000) % 60
        let s = (cs / 100) % 60
        let c = cs % 100
        if h > 0 { return "\(h):\(pad(m, 2)):\(pad(s, 2)).\(pad(c, 2))" }
        return "\(m):\(pad(s, 2)).\(pad(c, 2))"
    }

    /// Parses what a person types in the editor: `H:MM:SS.cc`, `M:SS.cc`, `SS.cc` or `HH:MM:SS,mmm`.
    public static func parseFlexible(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 3: return parse(trimmed, fractionSeparators: [".", ","])
        case 2: return parse("0:" + trimmed, fractionSeparators: [".", ","])
        case 1: return parse("0:0:" + trimmed, fractionSeparators: [".", ","])
        default: return nil
        }
    }

    private static func parse(_ raw: String, fractionSeparators: [Character]) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              hours >= 0, minutes >= 0 else { return nil }
        let secondsPart = parts[2]
        var wholeSeconds = Substring(secondsPart)
        var fraction = Substring("")
        if let sep = secondsPart.firstIndex(where: { fractionSeparators.contains($0) }) {
            wholeSeconds = secondsPart[..<sep]
            fraction = secondsPart[secondsPart.index(after: sep)...]
        }
        guard let seconds = Int(wholeSeconds), seconds >= 0 else { return nil }
        var fractionMs = 0
        if !fraction.isEmpty {
            guard fraction.allSatisfy(\.isNumber), fraction.count <= 3, let value = Int(fraction) else { return nil }
            switch fraction.count {
            case 1: fractionMs = value * 100
            case 2: fractionMs = value * 10
            default: fractionMs = value
            }
        }
        return ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fractionMs
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
