import Foundation

/// Any server speaking the OpenAI Chat Completions protocol: local ones (Ollama at
/// `http://localhost:11434/v1`, LM Studio at `http://localhost:1234/v1`, llama.cpp's server)
/// or optional online services. The API key is read from the Keychain by the caller and only
/// travels in the `Authorization` header; it is never logged.
public struct OpenAICompatibleEngine: TranslationEngine {
    public struct Configuration: Sendable, Hashable, Codable {
        public var name: String
        public var baseURL: URL
        public var model: String
        public var temperature: Double
        public var batchSize: Int
        public var requestTimeout: TimeInterval

        public init(name: String, baseURL: URL, model: String, temperature: Double = 0.3, batchSize: Int = 25, requestTimeout: TimeInterval = 300) {
            self.name = name
            self.baseURL = baseURL
            self.model = model
            self.temperature = temperature
            self.batchSize = batchSize
            self.requestTimeout = requestTimeout
        }

        public static let ollama = Configuration(name: String(localized: "Ollama (local)"), baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen3:8b")
        public static let lmStudio = Configuration(name: String(localized: "LM Studio (local)"), baseURL: URL(string: "http://localhost:1234/v1")!, model: "")

        public var isLocal: Bool { ["localhost", "127.0.0.1", "::1"].contains(baseURL.host() ?? "") }
    }

    public let configuration: Configuration
    private let apiKey: String?
    private let session: URLSession

    public var id: String { "openai-compatible:\(configuration.baseURL.absoluteString)|\(configuration.model)" }
    public var displayName: String { "\(configuration.name) · \(configuration.model)" }
    public let keepsPlaceholders = true
    public let usesContext = true
    public var preferredBatchSize: Int { max(1, configuration.batchSize) }

    public init(configuration: Configuration, apiKey: String?, session: URLSession = .shared) {
        self.configuration = configuration
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.session = session
    }

    public func availability(source: String?, target: String) async -> EngineAvailability {
        guard !configuration.model.isEmpty else { return .needsSetup(String(localized: "Informe o modelo a usar em Ajustes › Tradução.")) }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("models"), timeoutInterval: 5)
        authorize(&request)
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .needsSetup(String(localized: "A chave de API foi recusada pelo servidor.")) }
            return (200..<300).contains(code) ? .available : .unavailable(String(localized: "O servidor respondeu com o código \(code)."))
        } catch {
            return .needsSetup(configuration.isLocal
                ? String(localized: "Não há servidor em \(configuration.baseURL.absoluteString). Abra o Ollama ou o LM Studio.")
                : String(localized: "Sem conexão com \(configuration.baseURL.host() ?? String(localized: "o servidor"))."))
        }
    }

    public func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String] {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        let system = PromptBuilder.instructions(for: context)
            + "\n\nResponda apenas com JSON no formato {\"translations\":[{\"id\":<id>,\"text\":\"<tradução>\"}]}."
        let body = ChatRequest(model: configuration.model, temperature: configuration.temperature,
                               messages: [.init(role: "system", content: system),
                                          .init(role: "user", content: PromptBuilder.batchPrompt(lines, context: context))],
                               response_format: .init(type: "json_object"))
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TranslationEngineError.transient(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: break
        case 401, 403: throw TranslationEngineError.permanent(String(localized: "A chave de API foi recusada (\(code))."))
        case 404: throw TranslationEngineError.permanent(String(localized: "Modelo ou endereço não encontrado (\(code)). Confira o modelo “\(configuration.model)”."))
        case 408, 409, 425, 429, 500...599: throw TranslationEngineError.transient(String(localized: "o servidor respondeu \(code)"))
        default: throw TranslationEngineError.permanent(String(localized: "O servidor respondeu com o código \(code)."))
        }
        guard let reply = try? JSONDecoder().decode(ChatResponse.self, from: data), let content = reply.choices.first?.message.content else {
            throw TranslationEngineError.invalidResponse(String(localized: "resposta sem conteúdo"))
        }
        return try PromptBuilder.parseJSONTranslations(content)
    }

    private func authorize(_ request: inout URLRequest) {
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct ResponseFormat: Encodable { let type: String }
        let model: String
        let temperature: Double
        let messages: [Message]
        let response_format: ResponseFormat
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }
}
