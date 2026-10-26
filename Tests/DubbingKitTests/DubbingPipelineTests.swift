import AVFoundation
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

private let tools = ToolLocator()
private let canRun = tools.locate(.ffmpeg) != nil && tools.locate(.ffprobe) != nil
    && AVSpeechSynthesisVoice.speechVoices().contains { $0.name == "Luciana" }

@Suite("Voice-over dub (real say + FFmpeg)", .enabled(if: canRun), .serialized)
struct DubbingPipelineTests {
    private func makeMedia(in dir: URL) async throws -> MediaInfo {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ep.mkv")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), [
            "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=6",
            "-f", "lavfi", "-i", "sine=frequency=330:duration=6", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", url.path])
        return try await MediaInspector(tools: tools).inspect(url)
    }

    @Test func dubsAnEpisodeAndReusesClips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSDub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try await makeMedia(in: dir)
        let segments = [
            DubSegment(id: 1, start: 500, end: 2_400, speaker: "Kirito", text: "Eu não vou deixar você machucar meus amigos!"),
            DubSegment(id: 2, start: 3_000, end: 3_600, speaker: "Asuna", text: "Espera, Kirito, aonde você vai com tanta pressa agora?")
        ]
        let cast = VoiceCast(members: [CastMember(name: "Kirito", voiceID: "Luciana"), CastMember(name: "Asuna", voiceID: "Luciana")])
        let pipeline = DubbingPipeline(synthesizer: SystemVoiceSynthesizer(), tools: tools, workDirectory: dir.appendingPathComponent("work"), cast: cast)
        let output = dir.appendingPathComponent("dub.m4a")
        let report = try await pipeline.run(segments, media: media, audioTrack: media.tracks(.audio)[0], output: output)
        #expect(report.synthesized == 2 && report.failed.isEmpty)
        #expect(report.spedUp.contains(2))
        let dubbed = try await MediaInspector(tools: tools).inspect(output)
        #expect(dubbed.tracks(.audio).count == 1)
        let length = try await AudioMixer(tools: tools).duration(of: output)
        #expect(abs(length - 6_000) < 400, "\(length) ms")

        let again = try await pipeline.run(segments, media: media, audioTrack: media.tracks(.audio)[0], output: output)
        #expect(again.synthesized == 0 && again.reusedClips == 2)
    }

    @Test func speakersWithoutVoiceAreReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSDub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try await makeMedia(in: dir)
        let segments = [DubSegment(id: 1, start: 500, end: 2_000, speaker: "Klein", text: "Ei, pessoal!"),
                        DubSegment(id: 2, start: 2_500, end: 4_000, speaker: "Kirito", text: "Vamos lá.")]
        let cast = VoiceCast(members: [CastMember(name: "Kirito", voiceID: "Luciana")])
        let report = try await DubbingPipeline(synthesizer: SystemVoiceSynthesizer(), tools: tools, workDirectory: dir, cast: cast)
            .run(segments, media: media, audioTrack: media.tracks(.audio)[0], output: dir.appendingPathComponent("o.m4a"))
        #expect(report.failed.keys.sorted() == [1])
        #expect(report.synthesized == 1)
    }

    @Test func overlappingClipsAreDelayed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSDub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let clip = dir.appendingPathComponent("c.wav")
        do {
            // The writer must be released (file closed) before the clip is read back.
            let file = try AVAudioFile(forWriting: clip, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            try file.write(from: buffer)
        }
        let delayed = try AudioMixer(tools: tools).assembleVoiceTrack(
            [.init(id: 1, url: clip, start: 0), .init(id: 2, url: clip, start: 500)], totalDuration: 3_000, to: dir.appendingPathComponent("v.wav"))
        #expect(delayed == [2])
        let voice = try AVAudioFile(forReading: dir.appendingPathComponent("v.wav"))
        #expect(voice.length == 144_000)
    }
}
