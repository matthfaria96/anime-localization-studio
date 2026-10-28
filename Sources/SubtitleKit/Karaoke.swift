import Foundation

/// How a karaoke syllable lights up: switching color at once (`\k`), filling from left to
/// right over its time (`\kf`), or its outline appearing (`\ko`).
public enum KaraokeKind: String, Sendable, CaseIterable {
    case color = "k", fill = "kf", outline = "ko"
}

/// A karaoke line: the text split into syllables, each with how long it lasts (`{\k20}sa`),
/// in centiseconds as ASS writes it. Tags before the first syllable and next to each `\k`
/// are kept as they are.
public struct KaraokeLine: Sendable, Hashable {
    public struct Syllable: Sendable, Hashable {
        public var text: String
        public var centiseconds: Int
        public var kind: KaraokeKind
        /// Other tags of the syllable's block, before and after its `\k`.
        var before = ""
        var after = ""

        public init(text: String, centiseconds: Int, kind: KaraokeKind) {
            self.text = text
            self.centiseconds = centiseconds
            self.kind = kind
        }
    }

    public enum Split: Sendable { case syllable, word }

    /// Everything before the first syllable (usually the line's leading tags).
    public var prefix: String
    public var syllables: [Syllable]

    public var kind: KaraokeKind {
        get { syllables.first?.kind ?? .color }
        set { for i in syllables.indices { syllables[i].kind = newValue } }
    }

    public var totalMilliseconds: Int { syllables.reduce(0) { $0 + $1.centiseconds } * 10 }

    public var text: String {
        prefix + syllables.map { "{\($0.before)\\\($0.kind.rawValue)\($0.centiseconds)\($0.after)}\($0.text)" }.joined()
    }

    // MARK: Reading

    /// The karaoke of a line, or nil when it has no `\k` tags.
    public static func parse(_ raw: String) -> KaraokeLine? {
        var line = KaraokeLine(prefix: "", syllables: [])
        var found = false
        for token in ASSText.tokenize(raw) {
            if case .override(let block) = token,
               let match = block.range(of: #"\\(kf|ko|k|K)([0-9]+)"#, options: .regularExpression) {
                let tag = block[match].dropFirst()
                let name = String(tag.prefix { $0.isLetter })
                let kind: KaraokeKind = switch name {
                case "kf", "K": .fill
                case "ko": .outline
                default: .color
                }
                var syllable = Syllable(text: "", centiseconds: Int(tag.drop { $0.isLetter }) ?? 0, kind: kind)
                syllable.before = String(block[block.index(after: block.startIndex)..<match.lowerBound])
                syllable.after = String(block[match.upperBound..<block.index(before: block.endIndex)])
                line.syllables.append(syllable)
                found = true
            } else if found {
                line.syllables[line.syllables.count - 1].text += token.source
            } else {
                line.prefix += token.source
            }
        }
        return found ? line : nil
    }

    // MARK: Making

    /// Turns a plain line into karaoke: split by syllable or by word, with the line's
    /// duration spread over the syllables by how many letters each has.
    public static func make(from raw: String, duration: Int, by split: Split, kind: KaraokeKind) -> KaraokeLine {
        var prefix = ""
        var body = raw
        if case .override(let block) = ASSText.tokenize(raw).first, block.contains("\\") {
            prefix = block
            body = String(raw.dropFirst(block.count))
        }
        let plain = ASSText.plainText(body).replacingOccurrences(of: "\n", with: " ")
        var line = KaraokeLine(prefix: prefix, syllables: syllables(of: plain, by: split).map { Syllable(text: $0, centiseconds: 0, kind: kind) })
        line.distribute(over: duration)
        return line
    }

    /// Spreads `duration` (ms) over the syllables by their number of letters.
    public mutating func distribute(over duration: Int) {
        let total = max(0, duration / 10)
        let weights = syllables.map { max(1, $0.text.filter { $0.isLetter || $0.isNumber }.count) }
        let sum = max(1, weights.reduce(0, +))
        let exact = weights.map { Double(total) * Double($0) / Double(sum) }
        var parts = exact.map { Int($0) }
        let remainder = total - parts.reduce(0, +)
        let order = exact.indices.sorted { exact[$0] - Double(parts[$0]) > exact[$1] - Double(parts[$1]) }
        for i in order.prefix(remainder) { parts[i] += 1 }
        for i in syllables.indices { syllables[i].centiseconds = parts[i] }
    }

    /// Times marked while the line played: where each syllable begins (ms from the line
    /// start). The last one lasts until the line ends.
    public mutating func setStarts(_ starts: [Int], lineDuration: Int) {
        for i in syllables.indices where i < starts.count {
            let end = i + 1 < starts.count ? starts[i + 1] : lineDuration
            syllables[i].centiseconds = max(0, Int((Double(end - starts[i]) / 10).rounded()))
        }
    }

    /// Syllables of a line. Romaji is split the Japanese way (sa·ka·ra·u, a double consonant
    /// and a final n apart); kana, kanji and other scripts one character each; spaces and
    /// punctuation stay with the syllable before them.
    public static func syllables(of text: String, by split: Split) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { result.append(current); current = "" } }
        let characters = Array(text)
        if split == .word {
            for character in characters {
                if !character.isWhitespace, current.last?.isWhitespace == true { flush() }
                current.append(character)
            }
            flush()
            return result
        }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        for (i, character) in characters.enumerated() {
            let lower = Character(character.lowercased())
            if !(character.isLetter || character.isNumber) {
                if current.isEmpty, !result.isEmpty { result[result.count - 1].append(character) } else { current.append(character) }
                continue
            }
            if !character.isASCII {
                flush()
                result.append(String(character))
                continue
            }
            current.append(character)
            let next = i + 1 < characters.count ? Character(characters[i + 1].lowercased()) : nil
            if vowels.contains(lower) {
                flush()
            } else if current.count == 1, lower == "n", !(next.map { vowels.contains($0) || $0 == "y" } ?? false) {
                flush()
            } else if current.count == 1, lower != "n", next == lower {
                flush()
            }
        }
        flush()
        return result
    }
}

extension SubtitleDocument {
    /// No line has visible text (a subtitle just started).
    public var isBlank: Bool { cues.allSatisfy { $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// The spoken lines start or end at other times (or there are more or fewer of them).
    public func differsInTiming(from other: SubtitleDocument) -> Bool {
        let mine = cues.filter { !$0.isComment }, theirs = other.cues.filter { !$0.isComment }
        return mine.count != theirs.count || zip(mine, theirs).contains { abs($0.start - $1.start) > 10 || abs($0.end - $1.end) > 10 }
    }

    /// The same lines at the same times, with the same styles, characters and place on screen,
    /// and no text: to write another subtitle over this one's timing. SubRip becomes ASS.
    public func timingCopy(playResX: Int = 1920, playResY: Int = 1080) -> SubtitleDocument {
        switch self {
        case .ass(var doc):
            for i in 0..<doc.eventCount {
                doc.updateEvent(at: i) { event in
                    if case .override(let block) = ASSText.tokenize(event.text).first, block.contains("\\") { event.text = block } else { event.text = "" }
                }
            }
            return .ass(doc)
        case .srt:
            return .ass(ASSDocument.make(events: cues.map { (start: $0.start, end: $0.end, text: "", actor: $0.actor) },
                                         playResX: playResX, playResY: playResY))
        }
    }
}
