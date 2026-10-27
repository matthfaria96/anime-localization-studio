import Foundation
import Testing
@testable import DubbingKit
import SubtitleKit

@Suite("Dubbing plan")
struct DubbingPlanTests {
    let ass = """
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,nota
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,Kirito,0,0,0,,Eu não vou deixar!
    Dialogue: 0,0:00:03.10,0:00:04.00,Sign,,0,0,0,,{\\an8}Cidade do Início
    Dialogue: 0,0:00:04.10,0:00:05.00,Default,,0,0,0,,{\\pos(10,10)}Placa
    Dialogue: 0,0:00:05.00,0:00:06.00,Default,Asuna,0,0,0,,Espera,\\Nme escuta!
    Dialogue: 0,0:00:06.00,0:00:06.50,Default,Asuna,0,0,0,,Uma fala comprida demais para caber em meio segundo
    """

    @Test func keepsOnlySpokenDialogue() {
        let doc = SubtitleDocument.ass(ASSDocument.parse(text: ass))
        let segments = DubbingPlan.segments(from: doc)
        #expect(segments.map(\.speaker) == ["Kirito", "Asuna", "Asuna"])
        #expect(segments[1].text == "Espera, me escuta!")
        #expect(segments[1].slot == 1_000)
        #expect(segments[2].isLikelyTooLong)
        #expect(!segments[0].isLikelyTooLong)
        #expect(DubbingPlan.speakers(in: segments) == ["Kirito", "Asuna"])
    }

    @Test func castIsReusedBySpeakerLabel() {
        var cast = VoiceCast(members: [CastMember(name: "Kirito", voiceID: "v1", speakerLabels: ["SPEAKER_00"])])
        cast.addMissing(from: ["Kirito", "Asuna"])
        #expect(cast.members.count == 2)
        #expect(cast.member(for: "SPEAKER_00")?.voiceID == "v1")
        #expect(cast.member(for: "asuna")?.voiceID == nil)
    }
}

/// Serves canned ElevenLabs responses (test only).
final class StubElevenLabs: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCalls = 0
    nonisolated(unsafe) static var lastCreateBody: Data?
    nonisolated(unsafe) static var lastKey: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lastKey = request.value(forHTTPHeaderField: "xi-api-key")
        var code = 200
        var body = Data()
        if Self.lastKey != "good-key" {
            code = 401
            body = Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8)
        } else if request.httpMethod == "POST", path == "/v1/dubbing" {
            Self.lastCreateBody = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            }
            body = Data(#"{"dubbing_id":"dub-1","expected_duration_sec":1}"#.utf8)
        } else if path == "/v1/dubbing/dub-1" {
            Self.statusCalls += 1
            body = Data((Self.statusCalls < 2 ? #"{"dubbing_id":"dub-1","status":"dubbing"}"# : #"{"dubbing_id":"dub-1","status":"dubbed","target_languages":["pt"]}"#).utf8)
        } else if path == "/v1/dubbing/dub-1/audio/pt" {
            body = Data("ID3fake-mp3".utf8)
        } else if path == "/v1/user/subscription" {
            body = Data(#"{"tier":"creator","character_count":1000,"character_limit":100000}"#.utf8)
        } else {
            code = 404
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("ElevenLabs dubbing client", .serialized)
struct ElevenLabsDubbingTests {
    private func client(key: String) -> ElevenLabsDubbing {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubElevenLabs.self]
        return ElevenLabsDubbing(apiKey: key, session: URLSession(configuration: config))
    }

    @Test func dubsAnAudioFileFromStartToDownload() async throws {
        StubElevenLabs.statusCalls = 0
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("als-el-\(UUID().uuidString).m4a")
        try Data("fake-audio".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let el = client(key: "good-key")
        let job = try await el.createDub(audio: audio, name: "Episódio 1", targetLanguage: "pt-BR", sourceLanguage: "ja-JP")
        #expect(job.dubbing_id == "dub-1")
        let body = String(decoding: try #require(StubElevenLabs.lastCreateBody), as: UTF8.self)
        #expect(body.contains("name=\"target_lang\"\r\n\r\npt\r\n"), "ElevenLabs takes ISO 639-1 codes")
        #expect(body.contains("name=\"source_lang\"\r\n\r\nja\r\n"))
        #expect(body.contains("fake-audio"))
        try await el.waitUntilDubbed(job, every: .milliseconds(10))
        #expect(StubElevenLabs.statusCalls == 2)
        let out = audio.deletingPathExtension().appendingPathExtension("dub.mp3")
        defer { try? FileManager.default.removeItem(at: out) }
        try await el.downloadAudio("dub-1", language: "pt-BR", to: out)
        #expect(try Data(contentsOf: out) == Data("ID3fake-mp3".utf8))
        #expect(StubElevenLabs.lastKey == "good-key", "the key goes in xi-api-key")
    }

    @Test func explainsAWrongKeyAndAMissingOne() async throws {
        await #expect(throws: ElevenLabsDubbing.ServiceError.invalidKey) { try await client(key: "bad").account() }
        await #expect(throws: ElevenLabsDubbing.ServiceError.missingKey) { try await client(key: "").account() }
        let account = try await client(key: "good-key").account()
        #expect(account.remaining == 99_000)
    }

    @Test func mapsQuotaErrors() {
        let error = ElevenLabsDubbing.error(code: 401, body: Data(#"{"detail":{"status":"quota_exceeded","message":"This request exceeds your quota"}}"#.utf8))
        if case .noCredits = error {} else { Issue.record("expected noCredits, got \(error)") }
    }
}
@Suite("Dubbing plan edge cases")
struct DubbingPlanEdgeTests {
    @Test func linesWithoutWordsAreNotSpoken() {
        let doc = SubtitleDocument.ass(ASSDocument.parse(text: "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\an8}♪ ♪\nDialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,Olá!\n"))
        #expect(DubbingPlan.segments(from: doc).map(\.text) == ["Olá!"])
    }
}
