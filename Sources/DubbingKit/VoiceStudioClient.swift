import Foundation

/// Talks to a running VoiceStudio backend over its local HTTP API (default
/// `http://127.0.0.1:3900`). VoiceStudio is AGPL-3.0: the app never links, copies or bundles
/// its code; it is installed separately and used as an independent local service.
///
/// Endpoints used (verified in VoiceStudio v0.5.7, `backend/api/routers/openai_compat.py`
/// and `docs/speech-platform.md`):
/// - `GET  /.well-known/voicestudio-speech` — capability document (`voicestudio.speech.v1`)
/// - `GET  /v1/audio/voices` — voice profiles and aliases
/// - `POST /v1/audio/speech` — OpenAI-compatible TTS (`model`, `input` ≤ 4096 chars, `voice`, `language`, `speed`, `response_format`)
/// - `POST /v1/audio/transcriptions` — OpenAI-compatible ASR (multipart, `verbose_json` with segments)
public struct VoiceStudioClient: Sendable {
    public var baseURL: URL
    public var apiKey: String?
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:3900")!, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public enum ClientError: Error, LocalizedError, Equatable {
        case notRunning(String)
        case http(Int, String)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .notRunning(let url): "O VoiceStudio não está respondendo em \(url). Abra o VoiceStudio e aguarde o backend iniciar."
            case .http(let code, let message): "O VoiceStudio respondeu \(code): \(message)"
            case .badResponse: "O VoiceStudio respondeu num formato inesperado."
            }
        }
    }

    public struct Capabilities: Sendable, Hashable, Decodable {
        public let protocolName: String?

        enum CodingKeys: String, CodingKey { case protocolName = "protocol" }
    }

    public struct Voice: Sendable, Hashable, Decodable, Identifiable {
        public let voice_id: String
        public let name: String
        public let type: String?
        public let language: String?
        public var id: String { voice_id }
    }

    public struct TranscriptSegment: Sendable, Hashable, Decodable {
        public let start: Double
        public let end: Double
        public let text: String
        public let speaker: String?
    }

    public func capabilities() async throws -> Capabilities {
        let data = try await get("/.well-known/voicestudio-speech", timeout: 4)
        return (try? JSONDecoder().decode(Capabilities.self, from: data)) ?? Capabilities(protocolName: nil)
    }

    public func voices() async throws -> [Voice] {
        struct List: Decodable { let voices: [Voice]? ; let data: [Voice]? }
        let data = try await get("/v1/audio/voices", timeout: 10)
        if let list = try? JSONDecoder().decode(List.self, from: data) { return list.voices ?? list.data ?? [] }
        if let array = try? JSONDecoder().decode([Voice].self, from: data) { return array }
        throw ClientError.badResponse
    }

    /// Synthesizes one line as WAV.
    public func speech(_ text: String, voice: String, language: String = "pt", speed: Double = 1, model: String = "omnivoice",
                       instructions: String? = nil) async throws -> Data {
        struct Body: Encodable {
            let model: String, input: String, voice: String, response_format: String, speed: Double, language: String
            let instructions: String?
        }
        let body = Body(model: model, input: String(text.prefix(4096)), voice: voice, response_format: "wav",
                        speed: min(4, max(0.25, speed)), language: language, instructions: instructions)
        var request = makeRequest("/v1/audio/speech", timeout: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    /// Transcribes a WAV file with segment timestamps.
    public func transcribe(_ file: URL, language: String? = nil) async throws -> [TranscriptSegment] {
        let boundary = "ALS-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "segment")
        if let language { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = makeRequest("/v1/audio/transcriptions", timeout: 3_600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        struct Verbose: Decodable { let segments: [TranscriptSegment]? }
        let data = try await send(request)
        guard let verbose = try? JSONDecoder().decode(Verbose.self, from: data) else { throw ClientError.badResponse }
        return verbose.segments ?? []
    }

    // MARK: HTTP

    private func makeRequest(_ path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
        try await send(makeRequest(path, timeout: timeout))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ClientError.notRunning(baseURL.absoluteString)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ClientError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}
