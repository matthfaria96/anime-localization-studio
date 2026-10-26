import AVFoundation
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

private let tools = ToolLocator()
private let canRun = tools.locate(.ffmpeg) != nil && AVSpeechSynthesisVoice.speechVoices().contains { $0.name == "Luciana" }

/// RMS level in dBFS of a whole file.
private func rms(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    var sum = 0.0
    var count = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        let samples = buffer.floatChannelData![channel]
        for i in 0..<Int(buffer.frameLength) { sum += Double(samples[i] * samples[i]); count += 1 }
    }
    return 10 * log10(max(1e-12, sum / Double(max(1, count))))
}

@Suite("On-device dialogue separation (AUSoundIsolation)", .enabled(if: canRun), .serialized)
struct VoiceSeparatorTests {
    @Test func removesMostOfTheDialogueFromTheBackground() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSSep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ffmpeg = try tools.require(.ffmpeg)
        let speechRaw = dir.appendingPathComponent("speech-raw.wav")
        try await SystemVoiceSynthesizer().synthesize("Eu não vou deixar você machucar meus amigos. Precisamos chegar ao último andar.",
                                                      voice: "Luciana", style: nil, speed: 1, to: speechRaw)
        let speech = dir.appendingPathComponent("speech.wav"), music = dir.appendingPathComponent("music.wav")
        let mix = dir.appendingPathComponent("mix.wav"), leftover = dir.appendingPathComponent("leftover.wav")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", speechRaw.path, "-af", "apad=pad_dur=1",
                                                    "-ar", "48000", "-ac", "2", "-t", "6", speech.path])
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=220:d=6", "-f", "lavfi", "-i", "sine=f=330:d=6",
                                                    "-filter_complex", "[0][1]amix=inputs=2,volume=0.6", "-ar", "48000", "-ac", "2", music.path])
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", speech.path, "-i", music.path,
                                                    "-filter_complex", "[0][1]amix=inputs=2:normalize=0", "-ar", "48000", mix.path])
        let background = dir.appendingPathComponent("bg.wav")
        try await VoiceSeparator(tools: tools).separate(mix, voice: dir.appendingPathComponent("voice.wav"), background: background)
        // What is left of the speech in the background = background − music.
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", background.path, "-i", music.path,
                                                    "-filter_complex", "[1]volume=-1[n];[0][n]amix=inputs=2:normalize=0:duration=first", leftover.path])
        let reduction = try rms(speech) - rms(leftover)
        #expect(reduction > 10, "dialogue reduced by only \(reduction) dB")
        let length = try AVAudioFile(forReading: background).length
        #expect(abs(Double(length) - 6 * 48_000) < 4_800)
    }

    @Test func replaceModeProducesADub() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSRep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ep.mkv")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), [
            "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=5",
            "-f", "lavfi", "-i", "sine=frequency=330:duration=5", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path])
        let media = try await MediaInspector(tools: tools).inspect(url)
        let pipeline = DubbingPipeline(synthesizer: SystemVoiceSynthesizer(), tools: tools, workDirectory: dir.appendingPathComponent("work"),
                                       cast: VoiceCast(), options: DubbingOptions(defaultVoice: "Luciana", mode: .replaceDialogue))
        let output = dir.appendingPathComponent("dub.m4a")
        let report = try await pipeline.run([DubSegment(id: 0, start: 500, end: 3_000, speaker: "Desconhecido", text: "Vamos nessa!")],
                                            media: media, audioTrack: media.tracks(.audio)[0], output: output)
        #expect(report.failed.isEmpty)
        let length = try await AudioMixer(tools: tools).duration(of: output)
        #expect(abs(length - 5_000) < 400)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work/background-\(media.tracks(.audio)[0].id).wav").path))
    }
}
