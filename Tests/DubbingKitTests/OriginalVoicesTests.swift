import AVFoundation
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

private let tools = ToolLocator()
private let canRun = tools.locate(.ffmpeg) != nil && Set(AVSpeechSynthesisVoice.speechVoices().map(\.name)).isSuperset(of: ["Luciana", "Eddy"])

@Suite("Original voices and automatic casting", .enabled(if: canRun), .serialized)
struct OriginalVoicesTests {
    @Test func samplesEachSpeakerAndPicksSimilarVoices() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSVoices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ffmpeg = try tools.require(.ffmpeg)
        let turns = [("Luciana", "Bom dia, você viu o castelo flutuante hoje cedo?"), ("Eddy", "Vi sim, precisamos chegar ao último andar."),
                     ("Luciana", "Então vamos logo, sem perder tempo."), ("Eddy", "Certo, eu vou na frente e você me cobre.")]
        var lines: [OriginalVoices.Line] = []
        var parts: [URL] = []
        var cursor = 500
        for (n, turn) in turns.enumerated() {
            let url = dir.appendingPathComponent("\(n).wav")
            try await SystemVoiceSynthesizer().synthesize(turn.1, voice: turn.0, style: nil, speed: 1, to: url)
            let length = try await AudioMixer(tools: tools).duration(of: url)
            lines.append((n, cursor, cursor + length, turn.0 == "Luciana" ? "Falante 1" : "Falante 2", turn.1))
            parts.append(url)
            cursor += length + 500
        }
        let list = dir.appendingPathComponent("list.txt")
        let gap = dir.appendingPathComponent("gap.wav")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono", "-t", "0.5", "-c:a", "pcm_s16le", gap.path])
        try ([gap] + parts.flatMap { [$0, gap] }).map { "file '\($0.path)'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let episode = dir.appendingPathComponent("ep.mkv")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=15",
                                                    "-f", "concat", "-safe", "0", "-i", list.path, "-map", "0:v", "-map", "1:a", "-shortest",
                                                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", episode.path])
        let media = try await MediaInspector(tools: tools).inspect(episode)
        let samples = try await OriginalVoices(tools: tools, workDirectory: dir.appendingPathComponent("work"))
            .samples(for: lines, media: media, audioTrack: media.tracks(.audio)[0])
        #expect(samples.map(\.speaker) == ["Falante 1", "Falante 2"])
        #expect(samples.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        let female = try #require(samples[0].pitch), male = try #require(samples[1].pitch)
        #expect(female > male, "Luciana \(female) Hz, Eddy \(male) Hz")
        let voices = AutoCasting.systemVoices(for: samples, available: Set(AVSpeechSynthesisVoice.speechVoices().map(\.name)))
        #expect(AutoCasting.highSystemVoices.contains(voices["Falante 1"] ?? ""))
        #expect(AutoCasting.lowSystemVoices.contains(voices["Falante 2"] ?? ""))
        #expect(samples[0].text.contains("castelo"))

        // Each line's own original audio, for cloning voice and emotion line by line.
        let voices2 = OriginalVoices(tools: tools, workDirectory: dir.appendingPathComponent("work"))
        let clips = try await voices2.lineClips(for: lines, media: media, audioTrack: media.tracks(.audio)[0], minimumMilliseconds: 1_000)
        #expect(clips.count == lines.filter { $0.end - $0.start >= 1_000 }.count)
        for line in lines {
            guard let clip = clips[line.id] else { continue }
            let length = try await AudioMixer(tools: tools).duration(of: clip)
            // The episode is cut at 15 s, so a line past the end is clipped with the audio.
            let expected = min(line.end, media.durationMilliseconds ?? line.end) - line.start
            #expect(abs(length - expected) < 150, "line \(line.id): \(length) ms")
        }
        let none = try await voices2.lineClips(for: lines, media: media, audioTrack: media.tracks(.audio)[0], minimumMilliseconds: 60_000)
        #expect(none.isEmpty, "lines too short to clone from are left to the character sample")
    }
}

@Suite("Original voice languages")
struct OriginalVoiceLanguageTests {
    @Test func followsTheOutputLanguage() {
        #expect(ClonedVoiceSynthesizer.supports("pt-BR") && ClonedVoiceSynthesizer.supports("es") && ClonedVoiceSynthesizer.supports("fr"))
        #expect(!ClonedVoiceSynthesizer.supports("ja") && !ClonedVoiceSynthesizer.supports("ko"))
        let spanish = ClonedVoiceSynthesizer(modelsDirectory: URL(fileURLWithPath: "/tmp"), language: "es")
        let portuguese = ClonedVoiceSynthesizer(modelsDirectory: URL(fileURLWithPath: "/tmp"), language: "pt-BR")
        #expect(spanish.id != portuguese.id, "clips made in one language are never reused for another")
    }
}

@Suite("Voice cloning request", .serialized)
struct CloneRequestTests {
    @Test func sendsTheReferenceClipAsAMultipartCloneProfile() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubCloneServer.self]
        let client = VoiceStudioClient(baseURL: URL(string: "http://127.0.0.1:3998")!, session: URLSession(configuration: config))
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString).wav")
        try Data("RIFFfakewave".utf8).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let id = try await client.createCloneProfile(name: "Ep 1 · Falante 1", referenceAudio: clip, referenceText: "Bom dia", language: "pt")
        #expect(id == "prof-42")
        let body = String(decoding: try #require(StubCloneServer.lastBody), as: UTF8.self)
        #expect(body.contains("name=\"kind\"\r\n\r\nclone"))
        #expect(body.contains("name=\"ref_audio\"; filename=") && body.contains("RIFFfakewave"))
        #expect(body.contains("name=\"ref_text\"\r\n\r\nBom dia"))
    }
}

final class StubCloneServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 3998 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        Self.lastBody = body
        let ok = request.url?.path == "/profiles" && request.httpMethod == "POST"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"prof-42","name":"x"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
