import Foundation

/// ElevenLabs automatic dubbing over its HTTP API: it separates the voices from the music,
/// finds each speaker, translates, and speaks with a clone of each voice, keeping emotion and
/// timing. Only the audio is sent (never the video). The API key comes from the person's
/// account and is sent in the `xi-api-key` header.
///
/// Endpoints (ElevenLabs API reference, checked 27/10/2026):
/// - `POST /v1/dubbing` (multipart: `file`, `target_lang`, `source_lang`, `num_speakers`, `name`, `watermark`)
/// - `GET /v1/dubbing/{id}` → `status`, `error`, `target_languages`
/// - `GET /v1/dubbing/{id}/audio/{language}` → the dubbed MP3/MP4
/// - `DELETE /v1/dubbing/{id}`
/// - `GET /v1/user/subscription` → plan and credits (to check the key)
public struct ElevenLabsDubbing: Sendable {
    public var apiKey: String
    public var baseURL: URL
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.elevenlabs.io")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public enum ServiceError: Error, LocalizedError, Equatable {
        case missingKey
        case invalidKey
        case noCredits(String)
        case rejected(String)
        case failed(String)
        case offline

        public var errorDescription: String? {
            switch self {
            case .missingKey: "Falta a chave da ElevenLabs. Cole a sua em Dublar ou em Ajustes › Dublagem."
            case .invalidKey: "A ElevenLabs recusou a chave. Confira se ela foi copiada inteira e se tem permissão de dublagem."
            case .noCredits(let detail): "A conta da ElevenLabs não tem créditos suficientes para esta dublagem. \(detail)"
            case .rejected(let detail): "A ElevenLabs recusou o pedido: \(detail)"
            case .failed(let detail): "A dublagem falhou na ElevenLabs: \(detail)"
            case .offline: "Não foi possível falar com a ElevenLabs. Confira a conexão com a internet."
            }
        }
    }

    public struct Account: Sendable, Hashable, Decodable {
        public let tier: String?
        public let character_count: Int?
        public let character_limit: Int?

        public var remaining: Int? { character_limit.flatMap { limit in character_count.map { limit - $0 } } }
    }

    public struct Job: Sendable, Hashable, Decodable {
        public let dubbing_id: String
        public let expected_duration_sec: Double?

        public init(dubbing_id: String, expected_duration_sec: Double?) {
            self.dubbing_id = dubbing_id
            self.expected_duration_sec = expected_duration_sec
        }
    }

    public struct Status: Sendable, Hashable, Decodable {
        public let dubbing_id: String?
        public let status: String
        public let error: String?
        public let target_languages: [String]?

        public var isDone: Bool { status.lowercased() == "dubbed" }
        public var isFailed: Bool { ["failed", "error"].contains(status.lowercased()) || (error?.isEmpty == false && !isDone) }
    }

    /// ElevenLabs takes ISO 639-1 codes: `pt-BR` → `pt`.
    public static func languageCode(_ bcp47: String) -> String {
        String(bcp47.split(separator: "-").first ?? Substring(bcp47)).lowercased()
    }

    public func account() async throws -> Account {
        let data = try await send(request("GET", "/v1/user/subscription", timeout: 15))
        guard let account = try? JSONDecoder().decode(Account.self, from: data) else { throw ServiceError.failed("resposta inesperada") }
        return account
    }

    /// Starts a dub of `audio`. `sourceLanguage` nil lets ElevenLabs detect it.
    public func createDub(audio: URL, name: String, targetLanguage: String, sourceLanguage: String?, speakers: Int = 0) async throws -> Job {
        let boundary = "ALS-\(UUID().uuidString)"
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("name", name)
        field("target_lang", Self.languageCode(targetLanguage))
        if let sourceLanguage { field("source_lang", Self.languageCode(sourceLanguage)) }
        field("num_speakers", String(speakers))
        field("watermark", "false")
        let mime = audio.pathExtension.lowercased() == "mp3" ? "audio/mpeg" : "audio/mp4"
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audio))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = request("POST", "/v1/dubbing", timeout: 900)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await send(request)
        guard let job = try? JSONDecoder().decode(Job.self, from: data) else { throw ServiceError.failed("resposta inesperada") }
        return job
    }

    public func status(_ id: String) async throws -> Status {
        let data = try await send(request("GET", "/v1/dubbing/\(id)", timeout: 30))
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { throw ServiceError.failed("resposta inesperada") }
        return status
    }

    /// Waits until the dub is ready, reporting the elapsed share of the expected time.
    public func waitUntilDubbed(_ job: Job, every interval: Duration = .seconds(5),
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let expected = max(30, job.expected_duration_sec ?? 120)
        let started = Date()
        while true {
            try Task.checkCancellation()
            let current = try await status(job.dubbing_id)
            if current.isDone { progress?(1); return }
            if current.isFailed { throw ServiceError.failed(current.error ?? current.status) }
            progress?(min(0.97, Date().timeIntervalSince(started) / expected))
            try await Task.sleep(for: interval)
        }
    }

    /// Downloads the dubbed audio (MP3 or MP4) to `destination`.
    public func downloadAudio(_ id: String, language: String, to destination: URL) async throws {
        let data = try await send(request("GET", "/v1/dubbing/\(id)/audio/\(Self.languageCode(language))", timeout: 600))
        try data.write(to: destination, options: .atomic)
    }

    public func delete(_ id: String) async throws {
        _ = try await send(request("DELETE", "/v1/dubbing/\(id)", timeout: 30))
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        guard !apiKey.isEmpty else { throw ServiceError.missingKey }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ServiceError.offline
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Self.error(code: code, body: data) }
        return data
    }

    /// Turns an HTTP error into what happened, using the API's `detail` message when present.
    static func error(code: Int, body: Data) -> ServiceError {
        let detail = Self.detail(in: body)
        switch code {
        case 401, 403: return detail.lowercased().contains("quota") || detail.lowercased().contains("credit") ? .noCredits(detail) : .invalidKey
        case 402: return .noCredits(detail)
        default:
            if detail.lowercased().contains("quota") || detail.lowercased().contains("credits") { return .noCredits(detail) }
            return .rejected(detail.isEmpty ? "erro \(code)" : detail)
        }
    }

    static func detail(in body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return String(decoding: body.prefix(300), as: UTF8.self)
        }
        if let text = json["detail"] as? String { return text }
        if let object = json["detail"] as? [String: Any] { return (object["message"] as? String) ?? (object["status"] as? String) ?? "" }
        if let list = json["detail"] as? [[String: Any]] { return list.compactMap { $0["msg"] as? String }.joined(separator: "; ") }
        return ""
    }
}
