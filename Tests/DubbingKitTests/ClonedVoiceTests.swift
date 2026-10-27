import AVFoundation
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

/// The model lives where the app keeps it; the test runs when it is there or with
/// ALS_CHATTERBOX=1 (one-time download, about 2 GB).
private let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Anime Localization Studio/Models/Chatterbox", isDirectory: true)
private let synthesizer = ClonedVoiceSynthesizer(modelsDirectory: modelsDirectory)
private let enabled = synthesizer.modelsInstalled || ProcessInfo.processInfo.environment["ALS_CHATTERBOX"] == "1"

/// MLX looks for its GPU kernels next to the binary that contains it (here, the test bundle)
/// as `mlx.metallib`; SwiftPM puts them in `mlx-swift_Cmlx.bundle` beside the test bundle.
/// The app gets the bundle copied into Contents/Resources by Scripts/build-app.sh.
private func installMetallibForTests() throws {
    var info = Dl_info()
    guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return }
    let binaryDir = URL(fileURLWithPath: String(cString: name)).deletingLastPathComponent()
    let target = binaryDir.appendingPathComponent("mlx.metallib")
    guard !FileManager.default.fileExists(atPath: target.path) else { return }
    let products = binaryDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = products.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    try FileManager.default.copyItem(at: source, to: target)
}

@Suite("Cloned Portuguese voice (Chatterbox, real model)", .enabled(if: enabled), .serialized)
struct ClonedVoiceTests {
    @Test func speaksUnderstandablePortugueseWithTheReferenceVoice() async throws {
        try installMetallibForTests()
        let tools = ToolLocator()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSChatterbox-\(UUID().uuidString)")
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
        print("Chatterbox synthesis took \(clock.now - start)")
        // Warm model, same cloned voice: the cost per line of an episode.
        let warm = clock.now
        for line in ["Espera, aonde você vai?", "Precisamos chegar ao último andar, custe o que custar."] {
            try await synthesizer.synthesize(line, voice: reference.path, style: nil, speed: 1, to: dir.appendingPathComponent("w.wav"))
        }
        print("Chatterbox warm, 2 lines: \(clock.now - warm)")
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
