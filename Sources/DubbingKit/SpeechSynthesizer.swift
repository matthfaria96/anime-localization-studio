import Foundation
import MediaKit

/// Turns one line of text into a WAV file.
public protocol SpeechSynthesizer: Sendable {
    /// Stable id, part of the clip cache key (changing engines regenerates the clips).
    var id: String { get }
    func synthesize(_ text: String, voice: String, style: String?, speed: Double, to url: URL) async throws
}

public enum SynthesisError: Error, LocalizedError, Equatable {
    case engineUnavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): m
        case .failed(let m): "A síntese da fala falhou: \(m)"
        }
    }
}

/// macOS's built-in voices through `/usr/bin/say` (Luciana, Eddy, Flo… for pt-BR).
/// Always available and fully local, but robotic: meant for drafts and timing checks.
public struct SystemVoiceSynthesizer: SpeechSynthesizer {
    public let id = "system-say"
    let executable = URL(fileURLWithPath: "/usr/bin/say")

    public init() {}

    public func synthesize(_ text: String, voice: String, style: String?, speed: Double, to url: URL) async throws {
        // `say` speaks about 175 words per minute by default.
        let rate = Int((175 * min(2, max(0.5, speed))).rounded())
        do {
            try await ProcessRunner.runChecked(executable, ["-v", voice, "-r", String(rate), "-o", url.path,
                                                            "--file-format=WAVE", "--data-format=LEI16@24000", "--", text])
        } catch let error as ProcessError {
            throw SynthesisError.failed(error.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw SynthesisError.failed("a voz “\(voice)” não gerou áudio") }
    }
}

/// VoiceStudio's OpenAI-compatible `/v1/audio/speech` (cloned or designed voices).
public struct VoiceStudioSynthesizer: SpeechSynthesizer {
    public let client: VoiceStudioClient
    public let model: String
    public var id: String { "voicestudio:\(model)" }

    public init(client: VoiceStudioClient, model: String = "omnivoice") {
        self.client = client
        self.model = model
    }

    public func synthesize(_ text: String, voice: String, style: String?, speed: Double, to url: URL) async throws {
        do {
            let audio = try await client.speech(text, voice: voice, language: "pt", speed: speed, model: model, instructions: style)
            try audio.write(to: url, options: .atomic)
        } catch let error as VoiceStudioClient.ClientError {
            if case .notRunning = error { throw SynthesisError.engineUnavailable(error.localizedDescription) }
            throw SynthesisError.failed(error.localizedDescription)
        }
    }
}
