import AVFoundation
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

/// Models live where the app keeps them; the test runs when they are there or with
/// ALS_POCKET=1 (one-time download, about 500 MB).
private let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Anime Localization Studio/Models/PocketTTS", isDirectory: true)
private let synthesizer = ClonedVoiceSynthesizer(modelsDirectory: modelsDirectory)
private let enabled = synthesizer.modelsInstalled || ProcessInfo.processInfo.environment["ALS_POCKET"] == "1"

@Suite("Cloned Portuguese voice (PocketTTS, real models)", .enabled(if: enabled), .serialized)
struct ClonedVoiceTests {
    @Test func speaksUnderstandablePortugueseWithTheReferenceVoice() async throws {
        let tools = ToolLocator()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSPocket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A reference voice (the "original" character), ~8 s.
        let reference = dir.appendingPathComponent("ref.wav")
        try await SystemVoiceSynthesizer().synthesize("Bom dia. Hoje nós vamos atravessar a floresta e chegar ao castelo antes do anoitecer, custe o que custar.",
                                                      voice: "Luciana", style: nil, speed: 1, to: reference)
        let output = dir.appendingPathComponent("out.wav")
        let clock = ContinuousClock()
        let start = clock.now
        try await synthesizer.synthesize("Eu não vou deixar você machucar os meus amigos.", voice: reference.path, style: nil, speed: 1, to: output)
        print("PocketTTS synthesis took \(clock.now - start)")
        // Warm model, same cloned voice: the cost per line of an episode.
        let warm = clock.now
        for line in ["Espera, aonde você vai?", "Precisamos chegar ao último andar, custe o que custar."] {
            try await synthesizer.synthesize(line, voice: reference.path, style: nil, speed: 1, to: dir.appendingPathComponent("w.wav"))
        }
        print("PocketTTS warm, 2 lines: \(clock.now - warm)")
        let length = try await AudioMixer(tools: tools).duration(of: output)
        #expect(length > 1_000 && length < 10_000, "\(length) ms")
        // Understandable Portuguese: Apple's pt-BR recognizer must read the words back.
        let wav = dir.appendingPathComponent("16k.wav")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-i", output.path, "-af", "adelay=500", "-ar", "16000", "-ac", "1", wav.path])
        let heard = try await SpeechTranscription().transcribe(wav, language: "pt-BR", allowModelDownload: false).map(\.text).joined(separator: " ").lowercased()
        print("Recognized: \(heard)")
        let words = ["deixar", "machucar", "amigos"].filter { heard.contains($0) }
        #expect(words.count >= 2, "heard: \(heard)")
    }
}
