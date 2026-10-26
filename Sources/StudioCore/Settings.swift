import DubbingKit
import Foundation
import MediaKit
import Security
import TranslationKit

public enum EngineChoice: String, Sendable, Codable, CaseIterable, Identifiable {
    case appleTranslation, foundationModels, openAICompatible

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .appleTranslation: "Tradução da Apple (no dispositivo)"
        case .foundationModels: "Apple Intelligence (modelo local)"
        case .openAICompatible: "Servidor compatível com OpenAI"
        }
    }

    public var summary: String {
        switch self {
        case .appleTranslation: "Rápida e privada. Traduz fala por fala, sem contexto nem glossário."
        case .foundationModels: "Privada, usa contexto, glossário e notas da obra. Modelo pequeno."
        case .openAICompatible: "Ollama, LM Studio ou um serviço online. Melhor qualidade com modelos grandes."
        }
    }
}

public enum DubbingEngineChoice: String, Sendable, Codable, CaseIterable, Identifiable {
    case system, voiceStudio

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: "Vozes do macOS (básicas, no Mac)"
        case .voiceStudio: "VoiceStudio (vozes naturais e clonadas)"
        }
    }
}

public struct AppSettings: Sendable, Hashable, Codable {
    public var engine: EngineChoice = .appleTranslation
    public var openAI: OpenAICompatibleEngine.Configuration = .ollama
    /// `nil` = detect from the subtitle.
    public var sourceLanguage: String? = nil
    public var targetLanguage: String = "pt-BR"
    public var contextLines: Int = 6
    public var translateKaraoke: Bool = false
    public var trackName: String = "Português (Brasil)"
    public var makeDefault: Bool = true
    public var placeNewTrackFirst: Bool = false
    public var toolPaths: [String: String] = [:]
    public var voiceStudioURL: URL = URL(string: "http://127.0.0.1:3900")!
    public var dubbingEngine: DubbingEngineChoice = .system
    public var dubbingDefaultVoice: String? = "Luciana"
    public var dubbingMaxSpeedup: Double = 1.3
    public var dubbingMode: DubbingMode = .voiceOver
    /// Reading speed above which a line is flagged (characters per second).
    public var maxReadingSpeed: Double = 20

    public init() {}

    public var toolLocator: ToolLocator {
        var overrides: [ExternalTool: URL] = [:]
        for (key, path) in toolPaths where !path.isEmpty {
            if let tool = ExternalTool(rawValue: key) { overrides[tool] = URL(fileURLWithPath: path) }
        }
        return ToolLocator(overrides: overrides)
    }

    public var translationOptions: TranslationOptions {
        TranslationOptions(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, contextLines: contextLines, translateKaraoke: translateKaraoke)
    }

    public func makeSynthesizer() -> any SpeechSynthesizer {
        switch dubbingEngine {
        case .system: SystemVoiceSynthesizer()
        case .voiceStudio: VoiceStudioSynthesizer(client: VoiceStudioClient(baseURL: voiceStudioURL))
        }
    }

    public func makeEngine(apiKey: String?) -> any TranslationEngine {
        switch engine {
        case .appleTranslation: AppleTranslationEngine()
        case .foundationModels: FoundationModelsEngine()
        case .openAICompatible: OpenAICompatibleEngine(configuration: openAI, apiKey: apiKey)
        }
    }

    // Decoding tolerates settings files written by older versions (missing keys keep defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        engine = (try? c.decode(EngineChoice.self, forKey: .engine)) ?? defaults.engine
        openAI = (try? c.decode(OpenAICompatibleEngine.Configuration.self, forKey: .openAI)) ?? defaults.openAI
        sourceLanguage = try? c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        targetLanguage = (try? c.decode(String.self, forKey: .targetLanguage)) ?? defaults.targetLanguage
        contextLines = (try? c.decode(Int.self, forKey: .contextLines)) ?? defaults.contextLines
        translateKaraoke = (try? c.decode(Bool.self, forKey: .translateKaraoke)) ?? defaults.translateKaraoke
        trackName = (try? c.decode(String.self, forKey: .trackName)) ?? defaults.trackName
        makeDefault = (try? c.decode(Bool.self, forKey: .makeDefault)) ?? defaults.makeDefault
        placeNewTrackFirst = (try? c.decode(Bool.self, forKey: .placeNewTrackFirst)) ?? defaults.placeNewTrackFirst
        toolPaths = (try? c.decode([String: String].self, forKey: .toolPaths)) ?? defaults.toolPaths
        voiceStudioURL = (try? c.decode(URL.self, forKey: .voiceStudioURL)) ?? defaults.voiceStudioURL
        dubbingEngine = (try? c.decode(DubbingEngineChoice.self, forKey: .dubbingEngine)) ?? defaults.dubbingEngine
        dubbingDefaultVoice = (try? c.decodeIfPresent(String.self, forKey: .dubbingDefaultVoice)) ?? defaults.dubbingDefaultVoice
        dubbingMaxSpeedup = (try? c.decode(Double.self, forKey: .dubbingMaxSpeedup)) ?? defaults.dubbingMaxSpeedup
        dubbingMode = (try? c.decode(DubbingMode.self, forKey: .dubbingMode)) ?? defaults.dubbingMode
        maxReadingSpeed = (try? c.decode(Double.self, forKey: .maxReadingSpeed)) ?? defaults.maxReadingSpeed
    }
}

public struct SettingsStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func load() -> AppSettings { (try? JSONFile.read(AppSettings.self, from: paths.settings)) ?? AppSettings() }
    public func save(_ settings: AppSettings) throws { try JSONFile.write(settings, to: paths.settings) }
}

/// API keys live only in the login Keychain, never in settings files or logs.
public enum KeychainStore {
    static let service = "com.witchmymac.animelocalizationstudio"

    public static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(_ value: String, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard !value.isEmpty else { SecItemDelete(base as CFDictionary); return }
        // Update in place first, so a failed write never loses the key that was there.
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Não foi possível salvar a chave no Keychain."])
        }
    }

    /// Account name for a server's key, e.g. `api-key:api.openai.com`.
    public static func account(for baseURL: URL) -> String { "api-key:\(baseURL.host() ?? baseURL.absoluteString)" }
}
