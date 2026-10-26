import Foundation

public struct GlossaryEntry: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case character, technique, place, organization, honorific, term

        public var label: String {
            switch self {
            case .character: "Personagem"
            case .technique: "Técnica"
            case .place: "Lugar"
            case .organization: "Organização"
            case .honorific: "Tratamento"
            case .term: "Termo"
            }
        }
    }

    public var id: UUID
    public var source: String
    /// The required rendering; equal to `source` for names that must stay unchanged.
    public var target: String
    public var kind: Kind
    public var note: String
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), source: String, target: String, kind: Kind = .term, note: String = "", caseSensitive: Bool = false) {
        self.id = id
        self.source = source
        self.target = target
        self.kind = kind
        self.note = note
        self.caseSensitive = caseSensitive
    }

    func occurs(in text: String) -> Bool { Self.containsWord(source, in: text, caseSensitive: caseSensitive) }
    func isRespected(in translation: String) -> Bool { Self.containsWord(target, in: translation, caseSensitive: caseSensitive) }

    /// Whole-word match, so “Asuna” does not match inside “Asunaro”.
    static func containsWord(_ word: String, in text: String, caseSensitive: Bool) -> Bool {
        guard !word.isEmpty else { return false }
        var options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        options.insert(.literal)
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: word, options: options, range: range) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            let boundary: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber) } ?? true }
            if boundary(before) && boundary(after) { return true }
            range = found.upperBound..<text.endIndex
        }
        return false
    }
}

/// A series' persistent glossary and notes, shared by every episode of a season.
public struct Glossary: Sendable, Hashable, Codable {
    public var entries: [GlossaryEntry]
    /// Synopsis, characters and relationships, tone and how people address each other.
    public var notes: String
    public var keepHonorifics: Bool

    public init(entries: [GlossaryEntry] = [], notes: String = "", keepHonorifics: Bool = true) {
        self.entries = entries
        self.notes = notes
        self.keepHonorifics = keepHonorifics
    }

    public func entries(occurringIn texts: [String]) -> [GlossaryEntry] {
        entries.filter { entry in texts.contains { entry.occurs(in: $0) } }
    }

    public struct Violation: Sendable, Hashable, Codable {
        public var lineID: Int
        public var source: String
        public var expected: String
    }

    /// Lines where a glossary term appears in the source but its required rendering is absent.
    public func violations(source: [Int: String], translation: [Int: String]) -> [Violation] {
        source.keys.sorted().flatMap { id -> [Violation] in
            guard let text = source[id], let translated = translation[id] else { return [] }
            return entries.filter { $0.occurs(in: text) && !$0.isRespected(in: translated) }
                .map { Violation(lineID: id, source: $0.source, expected: $0.target) }
        }
    }
}
