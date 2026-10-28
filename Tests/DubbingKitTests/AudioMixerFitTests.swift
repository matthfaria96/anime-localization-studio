import AVFoundation
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

private let tools = ToolLocator()
private let canRun = tools.locate(.ffmpeg) != nil && AVSpeechSynthesisVoice.speechVoices().contains { $0.name == "Luciana" }

@Suite("Fitting a line to its time", .enabled(if: canRun))
struct AudioMixerFitTests {
    @Test func appliesTheCharacterSpeedAndStillSpeedsUpLinesThatDoNotFit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSFit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("line.wav")
        try await SystemVoiceSynthesizer().synthesize("Precisamos chegar ao último andar antes do anoitecer.", voice: "Luciana", to: raw)
        let mixer = AudioMixer(tools: tools)

        let natural = try await mixer.fit(raw, slot: 60_000, maxSpeedup: 1.3, to: dir.appendingPathComponent("natural.wav"))
        #expect(abs(natural.tempo - 1) < 0.001)

        let slower = try await mixer.fit(raw, slot: 60_000, speed: 0.8, maxSpeedup: 1.3, to: dir.appendingPathComponent("slower.wav"))
        #expect(abs(slower.tempo - 0.8) < 0.001)
        #expect(Double(slower.duration) > Double(natural.duration) * 1.15, "\(slower.duration) ms vs \(natural.duration) ms")

        let faster = try await mixer.fit(raw, slot: 60_000, speed: 1.25, maxSpeedup: 1.3, to: dir.appendingPathComponent("faster.wav"))
        #expect(abs(faster.tempo - 1.25) < 0.001)
        #expect(Double(faster.duration) < Double(natural.duration) * 0.9)

        // A slow character in a short slot is still sped up to fit, up to the maximum.
        let tight = try await mixer.fit(raw, slot: natural.duration / 2, speed: 0.8, maxSpeedup: 1.3, to: dir.appendingPathComponent("tight.wav"))
        #expect(abs(tight.tempo - 1.3) < 0.001)
        #expect(tight.overflows)
    }
}
