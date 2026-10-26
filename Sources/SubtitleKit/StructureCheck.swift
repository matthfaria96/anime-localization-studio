import Foundation

/// Confirms that a translated document differs from its source only where translation may
/// change it: the text of event lines. Everything else (headers, styles, timing, layers,
/// margins, effects, embedded fonts, comments, line order) must be identical.
public enum StructureCheck {
    public struct Report: Sendable, Hashable {
        public var problems: [String] = []
        public var changedTextLines = 0
        public var isValid: Bool { problems.isEmpty }
    }

    public static func compare(source: SubtitleDocument, translated: SubtitleDocument) -> Report {
        var report = Report()
        switch (source, translated) {
        case let (.ass(a), .ass(b)):
            compareASS(a, b, into: &report)
        case let (.srt(a), .srt(b)):
            guard a.cues.count == b.cues.count else {
                report.problems.append("Número de falas mudou: \(a.cues.count) → \(b.cues.count).")
                return report
            }
            if a.preamble != b.preamble { report.problems.append("O início do arquivo SRT mudou.") }
            for (i, (x, y)) in zip(a.cues, b.cues).enumerated() {
                if x.start != y.start || x.end != y.end { report.problems.append("Fala \(i + 1): tempo alterado.") }
                if x.text != y.text { report.changedTextLines += 1 }
            }
        default:
            report.problems.append("O formato da legenda mudou.")
        }
        return report
    }

    private static func compareASS(_ a: ASSDocument, _ b: ASSDocument, into report: inout Report) {
        guard a.lines.count == b.lines.count else {
            report.problems.append("Número de linhas do documento mudou: \(a.lines.count) → \(b.lines.count).")
            return
        }
        for (offset, (x, y)) in zip(a.lines, b.lines).enumerated() {
            switch (x, y) {
            case let (.event(e1), .event(e2)):
                guard e1.kind == e2.kind, e1.format == e2.format else {
                    report.problems.append("Linha \(offset + 1): tipo de evento alterado.")
                    continue
                }
                let textIndex = e1.index(of: "Text")
                for i in e1.fields.indices where i != textIndex && e1.fields[i] != e2.fields[i] {
                    report.problems.append("Linha \(offset + 1): campo \(e1.format[safe: i] ?? "#\(i)") alterado.")
                }
                if e1.text != e2.text { report.changedTextLines += 1 }
            default:
                if x != y { report.problems.append("Linha \(offset + 1) fora dos eventos foi alterada.") }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
