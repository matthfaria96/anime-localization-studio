import Foundation
import MediaKit

/// Turns one line of text into a WAV file.
public protocol SpeechSynthesizer: Sendable {
    /// Stable id, part of the clip cache key (changing engines regenerates the clips).
    var id: String { get }
    func synthesize(_ text: String, voice: String, to url: URL) async throws
}

public enum SynthesisError: Error, LocalizedError, Equatable {
    case engineUnavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): m
        case .failed(let m): String(localized: "A síntese da fala falhou: \(m)")
        }
    }
}

/// macOS's built-in voices through `/usr/bin/say` (Luciana, Eddy, Flo… for pt-BR). Not offered
/// in the app (robotic); kept because the tests use it to make speech to analyze.
public struct SystemVoiceSynthesizer: SpeechSynthesizer {
    public let id = "system-say"
    let executable = URL(fileURLWithPath: "/usr/bin/say")

    public init() {}

    public func synthesize(_ text: String, voice: String, to url: URL) async throws {
        do {
            try await ProcessRunner.runChecked(executable, ["-v", voice, "-o", url.path,
                                                            "--file-format=WAVE", "--data-format=LEI16@24000", "--", text])
        } catch let error as ProcessError {
            throw SynthesisError.failed(error.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw SynthesisError.failed(String(localized: "a voz “\(voice)” não gerou áudio")) }
    }
}
