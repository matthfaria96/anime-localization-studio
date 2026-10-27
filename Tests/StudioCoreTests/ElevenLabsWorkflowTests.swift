import CryptoKit
import DubbingKit
import Foundation
import MediaKit
import Testing
import TranslationKit
@testable import StudioCore

private let tools = ToolLocator()
private let canRun = [ExternalTool.mkvmerge, .mkvextract, .ffmpeg, .ffprobe].allSatisfy { tools.locate($0) != nil }

/// A pretend ElevenLabs that “dubs” by returning a prepared audio file.
final class FakeElevenLabs: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var dubbedAudio = Data()
    nonisolated(unsafe) static var creates = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = Data()
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "/v1/dubbing"):
            Self.creates += 1
            body = Data(#"{"dubbing_id":"job-9","expected_duration_sec":1}"#.utf8)
        case (_, "/v1/dubbing/job-9"): body = Data(#"{"dubbing_id":"job-9","status":"dubbed"}"#.utf8)
        case (_, "/v1/dubbing/job-9/audio/pt"): body = Self.dubbedAudio
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Online dub (ElevenLabs simulated, real tools)", .enabled(if: canRun), .serialized)
struct ElevenLabsWorkflowTests {
    @Test func dubbedAudioBecomesANewVerifiedTrack() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSOnline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        let media = base.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let ffmpeg = try tools.require(.ffmpeg)
        let raw = media.appendingPathComponent("raw.mkv")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=4",
                                                    "-f", "lavfi", "-i", "sine=frequency=330:duration=4", "-c:v", "libx264", "-preset", "ultrafast",
                                                    "-pix_fmt", "yuv420p", "-c:a", "aac", raw.path])
        let episode = media.appendingPathComponent("Show - 03.mkv")
        try await ProcessRunner.runChecked(try tools.require(.mkvmerge), ["-o", episode.path, "--language", "1:ja", raw.path], acceptedExitCodes: [0, 1])
        let originalHash = SHA256.hash(data: try Data(contentsOf: episode))
        let dubbed = media.appendingPathComponent("dubbed.mp3")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=660:duration=4", "-c:a", "libmp3lame", dubbed.path])
        FakeElevenLabs.dubbedAudio = try Data(contentsOf: dubbed)
        FakeElevenLabs.creates = 0

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeElevenLabs.self]
        let client = ElevenLabsDubbing(apiKey: "k", session: URLSession(configuration: config))
        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: AppleTranslationEngine(), glossary: Glossary())
        let project = ProjectStore(paths: paths).project(for: episode)
        let result = try await workflow.dubWithElevenLabs(project, client: client, audioTrackID: nil, replaceOriginal: false) { _ in }

        #expect(result.verification.passed, "\(result.verification.failures)")
        let audio = try #require(result.verification.outputInfo).tracks(.audio)
        #expect(audio.count == 2)
        #expect(audio.contains { ($0.languageIETF == "pt-BR" || $0.language == "por") && $0.isDefault && ($0.name ?? "").contains("ElevenLabs") })
        #expect(audio.contains { $0.language == "jpn" && !$0.isDefault })
        #expect(result.project.remoteDub == nil, "nothing left to resume")
        #expect(FakeElevenLabs.creates == 1)
        #expect(SHA256.hash(data: try Data(contentsOf: episode)) == originalHash, "the original is untouched")
    }

    @Test func anInterruptedDubIsResumedInsteadOfSentAgain() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSOnline2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let ffmpeg = try tools.require(.ffmpeg)
        let episode = base.appendingPathComponent("Show - 04.mkv")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=3",
                                                    "-f", "lavfi", "-i", "sine=frequency=330:duration=3", "-c:v", "libx264", "-preset", "ultrafast",
                                                    "-pix_fmt", "yuv420p", "-c:a", "aac", episode.path])
        let dubbed = base.appendingPathComponent("dubbed.mp3")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=660:duration=3", "-c:a", "libmp3lame", dubbed.path])
        FakeElevenLabs.dubbedAudio = try Data(contentsOf: dubbed)
        FakeElevenLabs.creates = 0
        let info = try await MediaInspector(tools: tools).inspect(episode)
        var project = ProjectStore(paths: paths).project(for: episode)
        project.remoteDub = RemoteDub(id: "job-9", language: "pt-BR", audioTrackID: try #require(info.tracks(.audio).first).id)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeElevenLabs.self]
        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: AppleTranslationEngine(), glossary: Glossary())
        let result = try await workflow.dubWithElevenLabs(project, client: ElevenLabsDubbing(apiKey: "k", session: URLSession(configuration: config)),
                                                          audioTrackID: nil, replaceOriginal: false) { _ in }
        #expect(result.verification.passed, "\(result.verification.failures)")
        #expect(FakeElevenLabs.creates == 0, "the dub already on ElevenLabs is not paid for again")
    }
}
