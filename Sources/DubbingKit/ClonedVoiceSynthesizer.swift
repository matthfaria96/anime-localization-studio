import FluidAudio
import Foundation

/// Speaks Portuguese with a clone of each character's original voice, on the Mac: Kyutai's
/// PocketTTS (Core ML, via FluidAudio) conditions the speech on 1–30 s of the original voice.
/// `voice` is the path of that reference clip (made by `OriginalVoices`). No server needed.
/// Models (CC-BY-4.0, about 500 MB) are downloaded only after the person confirms.
public struct ClonedVoiceSynthesizer: SpeechSynthesizer {
    public let id = "pocket-tts-pt"
    public let modelsDirectory: URL

    public static let downloadSize = "cerca de 500 MB"
    public static let modelCredits = "Pocket TTS da Kyutai (CC-BY-4.0), conversão Core ML da Fluid Inference"

    public init(modelsDirectory: URL) { self.modelsDirectory = modelsDirectory }

    /// Whether the Portuguese pack and the cloning encoder are already on disk.
    public var modelsInstalled: Bool {
        let fm = FileManager.default
        var hasPack = false, hasEncoder = false
        let enumerator = fm.enumerator(at: modelsDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "flowlm_stepv2.mlmodelc", url.path.contains("portuguese") { hasPack = true }
            if url.lastPathComponent.hasPrefix("mimi_encoder"), url.pathExtension == "mlmodelc" { hasEncoder = true }
            if hasPack && hasEncoder { return true }
        }
        return false
    }

    public func synthesize(_ text: String, voice: String, style: String?, speed: Double, to url: URL) async throws {
        do {
            let audio = try await PocketEngine.shared.speak(text, reference: URL(fileURLWithPath: voice), modelsDirectory: modelsDirectory)
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
        try await PocketEngine.shared.manager(for: modelsDirectory)
    }
}

/// One loaded model for the whole app, and the cloned voices already computed.
actor PocketEngine {
    static let shared = PocketEngine()
    private var loaded: (URL, PocketTtsManager)?
    private var voices: [URL: PocketTtsVoiceData] = [:]

    @discardableResult
    func manager(for directory: URL) async throws -> PocketTtsManager {
        if let (dir, manager) = loaded, dir == directory { return manager }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = PocketTtsManager(language: .portuguese, directory: directory, precision: .int8)
        try await manager.initialize()
        loaded = (directory, manager)
        voices = [:]
        return manager
    }

    func speak(_ text: String, reference: URL, modelsDirectory: URL) async throws -> Data {
        let manager = try await manager(for: modelsDirectory)
        let voice: PocketTtsVoiceData
        if let cached = voices[reference] {
            voice = cached
        } else {
            voice = try await manager.cloneVoice(from: reference)
            voices[reference] = voice
        }
        return try await manager.synthesize(text: text, voiceData: voice)
    }
}
