import FluidAudio
import Foundation

/// Speaks the output language with a clone of each character's original voice, on the Mac:
/// Kyutai's PocketTTS (Core ML, via FluidAudio) conditions the speech on 1–30 s of the original
/// voice. `voice` is the path of that reference clip (made by `OriginalVoices`): the character's
/// sample, or the original audio of the very line, which carries its emotion too.
/// Each language is its own model pack (CC-BY-4.0), downloaded only after the person confirms.
public struct ClonedVoiceSynthesizer: SpeechSynthesizer {
    public let id: String
    public let modelsDirectory: URL
    /// The PocketTTS pack for the output language, or nil when there is none.
    let pack: PocketTtsLanguage?
    public let languageName: String

    public static let downloadSize = "cerca de 500 MB"
    public static let modelCredits = "Pocket TTS da Kyutai (CC-BY-4.0), conversão Core ML da Fluid Inference"

    public init(modelsDirectory: URL, language: String = "pt-BR") {
        self.modelsDirectory = modelsDirectory
        pack = Self.pack(for: language)
        languageName = Locale(identifier: "pt_BR").localizedString(forLanguageCode: String(language.prefix(2))) ?? language
        id = "pocket-tts-\(pack?.rawValue ?? "none")"
    }

    /// Output languages the on-device clone can speak.
    public static func pack(for language: String) -> PocketTtsLanguage? {
        switch String(language.prefix(2)).lowercased() {
        case "pt": .portuguese
        case "es": .spanish
        case "en": .english
        case "fr": .french24L
        case "de": .german
        case "it": .italian
        default: nil
        }
    }

    public static func supports(_ language: String) -> Bool { pack(for: language) != nil }

    /// Whether the language pack and the cloning encoder are already on disk.
    public var modelsInstalled: Bool {
        guard let pack else { return false }
        let fm = FileManager.default
        var hasPack = false, hasEncoder = false
        let enumerator = fm.enumerator(at: modelsDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix("flowlm_step"), url.pathComponents.contains(pack.rawValue) { hasPack = true }
            if url.lastPathComponent.hasPrefix("mimi_encoder"), url.pathExtension == "mlmodelc" { hasEncoder = true }
            if hasPack && hasEncoder { return true }
        }
        return false
    }

    public func synthesize(_ text: String, voice: String, style: String?, speed: Double, to url: URL) async throws {
        guard let pack else { throw unsupported }
        do {
            let audio = try await PocketEngine.shared.speak(text, reference: URL(fileURLWithPath: voice), language: pack, modelsDirectory: modelsDirectory)
            try audio.write(to: url, options: .atomic)
        } catch let error as SynthesisError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SynthesisError.failed(error.localizedDescription)
        }
    }

    /// Downloads (when missing) and loads the models, ahead of a dub.
    public func prepare() async throws {
        guard let pack else { throw unsupported }
        try await PocketEngine.shared.manager(for: modelsDirectory, language: pack)
    }

    private var unsupported: SynthesisError {
        .engineUnavailable("A voz original no Mac ainda não fala \(languageName). Ela fala português, espanhol, inglês, francês, alemão e italiano. Para \(languageName), use as vozes do macOS ou o VoiceStudio.")
    }
}

/// One loaded model for the whole app, and the cloned voices already computed. Character
/// samples are reused for many lines; line clips are used once, so only a few are kept.
actor PocketEngine {
    static let shared = PocketEngine()
    private var loaded: (URL, PocketTtsLanguage, PocketTtsManager)?
    private var voices: [URL: PocketTtsVoiceData] = [:]
    private var recent: [URL] = []
    private let keep = 24

    @discardableResult
    func manager(for directory: URL, language: PocketTtsLanguage) async throws -> PocketTtsManager {
        if let (dir, lang, manager) = loaded, dir == directory, lang == language { return manager }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = PocketTtsManager(language: language, directory: directory, precision: .int8)
        try await manager.initialize()
        loaded = (directory, language, manager)
        voices = [:]
        recent = []
        return manager
    }

    func speak(_ text: String, reference: URL, language: PocketTtsLanguage, modelsDirectory: URL) async throws -> Data {
        let manager = try await manager(for: modelsDirectory, language: language)
        let voice: PocketTtsVoiceData
        if let cached = voices[reference] {
            voice = cached
        } else {
            voice = try await manager.cloneVoice(from: reference)
            voices[reference] = voice
        }
        recent.removeAll { $0 == reference }
        recent.append(reference)
        while recent.count > keep { voices[recent.removeFirst()] = nil }
        return try await manager.synthesize(text: text, voiceData: voice)
    }
}
