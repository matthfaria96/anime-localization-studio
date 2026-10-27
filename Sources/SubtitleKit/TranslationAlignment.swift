import Foundation

/// Links an existing translation (another track or file, often with different line breaks
/// and line count) to the original: every original line takes the text of the translated line
/// that overlaps it the most in time. The original's structure, styles and timing are kept.
public enum TranslationAlignment {
    public struct Result: Sendable {
        public let document: SubtitleDocument
        public let matched: Int
        public let total: Int
    }

    public static func align(_ translation: SubtitleDocument, onto original: SubtitleDocument) -> Result {
        var output = original
        let sourceCues = original.cues
        let targetCues = translation.cues.filter { !$0.isComment && !$0.features.hasDrawing }
        let sameShape = translation.count == original.count
            && zip(sourceCues, translation.cues).allSatisfy { abs($0.start - $1.start) < 50 && abs($0.end - $1.end) < 50 }
        var matched = 0
        var total = 0
        for cue in sourceCues where !cue.isComment && !cue.features.hasDrawing {
            total += 1
            let match: SubtitleCue? = sameShape
                ? translation.cues[cue.id]
                : targetCues.max { overlap($0, cue) < overlap($1, cue) }.flatMap { overlap($0, cue) > 0 ? $0 : nil }
            guard let match else { continue }
            // ASS → ASS keeps the translation's inline tags; across formats only the words move.
            // Plain text keeps the original's leading tags ({\an8}, {\pos(…)}), so the line stays in place.
            let prefix = original.translatable(at: cue.id)?.prefix ?? ""
            let text = original.usesHTMLMarkup == translation.usesHTMLMarkup ? match.rawText : prefix + match.plainText
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            output.setRawText(text, at: cue.id)
            matched += 1
        }
        return Result(document: output, matched: matched, total: total)
    }

    static func overlap(_ a: SubtitleCue, _ b: SubtitleCue) -> Int { max(0, min(a.end, b.end) - max(a.start, b.start)) }
}
