import Foundation

/// Matches the lines of two subtitles by time (they often differ in line breaks and line count).
public enum TranslationAlignment {
    /// Text of another subtitle to show beside `original` (read only): for each line, the plain
    /// text of the other subtitle's line that overlaps it the most. Lines with no match are absent.
    public static func reference(_ other: SubtitleDocument, for original: SubtitleDocument) -> [Int: String] {
        let candidates = other.cues.filter { !$0.isComment && !$0.features.hasDrawing }
        var lines: [Int: String] = [:]
        for cue in original.cues where !cue.isComment {
            guard let match = candidates.max(by: { overlap($0, cue) < overlap($1, cue) }), overlap(match, cue) > 0 else { continue }
            let text = match.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines[cue.id] = text }
        }
        return lines
    }

    static func overlap(_ a: SubtitleCue, _ b: SubtitleCue) -> Int { max(0, min(a.end, b.end) - max(a.start, b.start)) }
}
