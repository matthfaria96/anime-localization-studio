import Foundation
import NaturalLanguage
import Translation

/// Apple's on-device Translation framework. Free, private and fast, but context-free: each
/// line is translated on its own and the glossary can only be checked afterwards. Languages
/// must be downloaded first (System Settings › General › Language & Region › Translation
/// Languages, or the app's “Preparar idiomas” button).
public struct AppleTranslationEngine: TranslationEngine {
    public let id = "apple-translation"
    public let displayName = String(localized: "Tradução da Apple (no dispositivo)")
    public let keepsPlaceholders = false
    public let usesContext = false
    public let preferredBatchSize = 40

    public init() {}

    public func availability(source: String?, target: String) async -> EngineAvailability {
        guard let source else { return .needsSetup(String(localized: "Escolha o idioma de origem para usar a tradução da Apple.")) }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        switch status {
        case .installed: return .available
        case .supported: return .needsSetup(String(localized: "Os idiomas \(source) → \(target) precisam ser baixados (Ajustes do Sistema › Geral › Idioma e Região › Idiomas de Tradução)."))
        case .unsupported: return .unavailable(String(localized: "A tradução da Apple não oferece \(source) → \(target)."))
        @unknown default: return .unavailable(String(localized: "Estado de idioma desconhecido."))
        }
    }

    public func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String] {
        guard let source = context.sourceLanguage else {
            throw TranslationEngineError.permanent(String(localized: "A tradução da Apple precisa do idioma de origem."))
        }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: context.targetLanguage))
        guard status == .installed else {
            throw TranslationEngineError.permanent(String(localized: "Os idiomas \(source) → \(context.targetLanguage) não estão baixados neste Mac."))
        }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: context.targetLanguage))
        let requests = lines.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
        do {
            let responses = try await session.translations(from: requests)
            var result: [Int: String] = [:]
            for response in responses {
                if let id = response.clientIdentifier.flatMap(Int.init) { result[id] = response.targetText }
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationEngineError.transient(error.localizedDescription)
        }
    }

    /// Most likely language of a set of lines (BCP 47), for engines that need the source.
    public static func detectLanguage(of texts: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.prefix(200).joined(separator: "\n"))
        return recognizer.dominantLanguage?.rawValue
    }
}
