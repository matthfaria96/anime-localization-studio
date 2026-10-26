import Foundation

/// One line sent to an engine. `text` may contain `⟦n⟧` placeholders for inline tags.
public struct TranslationLine: Sendable, Hashable, Codable {
    public var id: Int
    public var text: String
    public var speaker: String?

    public init(id: Int, text: String, speaker: String? = nil) {
        self.id = id
        self.text = text
        self.speaker = speaker
    }
}

/// What an engine may use beyond the lines themselves.
public struct TranslationContext: Sendable, Hashable {
    /// BCP 47, or `nil` to let the engine detect it.
    public var sourceLanguage: String?
    public var targetLanguage: String
    /// Lines just before the batch (source, translation), for continuity of tone and pronouns.
    public var previousLines: [PreviousLine]
    /// Glossary entries that occur in the batch.
    public var glossary: [GlossaryEntry]
    /// Series notes: synopsis, characters, how characters address each other.
    public var notes: String
    public var keepHonorifics: Bool

    public struct PreviousLine: Sendable, Hashable, Codable {
        public var speaker: String?
        public var source: String
        public var translation: String

        public init(speaker: String?, source: String, translation: String) {
            self.speaker = speaker
            self.source = source
            self.translation = translation
        }
    }

    public init(sourceLanguage: String?, targetLanguage: String, previousLines: [PreviousLine] = [], glossary: [GlossaryEntry] = [],
                notes: String = "", keepHonorifics: Bool = true) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.previousLines = previousLines
        self.glossary = glossary
        self.notes = notes
        self.keepHonorifics = keepHonorifics
    }
}

public enum EngineAvailability: Sendable, Hashable {
    case available
    /// Usable after a step the person must take (download languages, start a server…).
    case needsSetup(String)
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
    public var message: String? {
        switch self {
        case .available: nil
        case .needsSetup(let m), .unavailable(let m): m
        }
    }
}

public enum TranslationEngineError: Error, LocalizedError, Equatable {
    /// Temporary: rate limits, timeouts, overloaded servers. The pipeline retries these.
    case transient(String)
    /// The engine answered, but not in the expected shape (missing ids, broken JSON…).
    case invalidResponse(String)
    /// The request itself cannot succeed (bad key, unsupported language, content refused).
    case permanent(String)

    public var errorDescription: String? {
        switch self {
        case .transient(let m): "Falha temporária do motor de tradução: \(m)"
        case .invalidResponse(let m): "Resposta inválida do motor de tradução: \(m)"
        case .permanent(let m): m
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .transient, .invalidResponse: true
        case .permanent: false
        }
    }
}

public protocol TranslationEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Whether the engine reliably returns `⟦n⟧` placeholders. When `false`, lines with inline
    /// tags are translated piece by piece instead.
    var keepsPlaceholders: Bool { get }
    /// Whether the engine uses `TranslationContext` (previous lines, glossary, notes).
    var usesContext: Bool { get }
    var preferredBatchSize: Int { get }

    func availability(source: String?, target: String) async -> EngineAvailability
    /// Returns a translation for every line id it was given.
    func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String]
}
