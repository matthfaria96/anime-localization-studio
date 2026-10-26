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

/// Serves canned VoiceStudio responses (test only).
final class StubVoiceStudio: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 3999 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        Self.lastBody = request.httpBody ?? body
        let (code, payload): (Int, String) = switch path {
        case "/.well-known/voicestudio-speech": (200, #"{"protocol":"voicestudio.speech.v1"}"#)
        case "/v1/audio/voices": (200, #"{"voices":[{"voice_id":"p1","name":"Kirito PT","type":"profile"}]}"#)
        case "/v1/audio/speech": (200, "RIFF....WAVE")
        default: (404, "not found")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("VoiceStudio client", .serialized)
struct VoiceStudioClientTests {
    let client: VoiceStudioClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubVoiceStudio.self]
        return VoiceStudioClient(baseURL: URL(string: "http://127.0.0.1:3999")!, session: URLSession(configuration: config))
    }()

    @Test func readsCapabilitiesAndVoices() async throws {
        #expect(try await client.capabilities().protocolName == "voicestudio.speech.v1")
        #expect(try await client.voices().map(\.name) == ["Kirito PT"])
    }

    @Test func sendsOpenAICompatibleSpeechRequests() async throws {
        let audio = try await client.speech("Olá", voice: "p1", speed: 9)
        #expect(audio.starts(with: Data("RIFF".utf8)))
        let body = try #require(StubVoiceStudio.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["voice"] as? String == "p1")
        #expect(json["response_format"] as? String == "wav")
        #expect(json["speed"] as? Double == 4)
    }

    @Test func reportsWhenNotRunning() async {
        let offline = VoiceStudioClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        await #expect(throws: VoiceStudioClient.ClientError.self) { try await offline.capabilities() }
    }
}

@Suite("Dubbing plan edge cases")
struct DubbingPlanEdgeTests {
    @Test func linesWithoutWordsAreNotSpoken() {
        let doc = SubtitleDocument.ass(ASSDocument.parse(text: "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\an8}♪ ♪\nDialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,Olá!\n"))
        #expect(DubbingPlan.segments(from: doc).map(\.text) == ["Olá!"])
    }
}
