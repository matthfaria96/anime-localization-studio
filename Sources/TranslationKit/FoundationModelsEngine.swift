import Foundation
import FoundationModels

/// Apple Intelligence's on-device language model (Foundation Models). Uses the glossary,
/// series notes and previous lines, with structured output so every id comes back. The model
/// is small and its context window is limited, so batches are short; quality is below large
/// cloud models but nothing leaves the Mac.
public struct FoundationModelsEngine: TranslationEngine {
    public let id = "apple-foundation-models"
    public let displayName = "Apple Intelligence (modelo local)"
    public let keepsPlaceholders = true
    public let usesContext = true
    public let preferredBatchSize = 10

    public init() {}

    @Generable
    struct Batch {
        @Guide(description: "Uma tradução para cada id recebido, na mesma ordem.")
        var translations: [Item]
    }

    @Generable
    struct Item {
        @Guide(description: "O id da fala de entrada.")
        var id: Int
        @Guide(description: "A fala traduzida, mantendo os marcadores ⟦n⟧.")
        var text: String
    }

    private var model: SystemLanguageModel {
        // Subtitles routinely contain fights, threats and swearing; the permissive guardrails
        // are Apple's mode for transforming existing text such as translation.
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    public func availability(source: String?, target: String) async -> EngineAvailability {
        switch model.availability {
        case .available:
            let language = Locale.Language(identifier: target)
            let supported = model.supportedLanguages.contains { $0.languageCode == language.languageCode }
            return supported ? .available : .unavailable("O modelo local não escreve em \(target).")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .needsSetup("Ative a Apple Intelligence em Ajustes do Sistema para usar o modelo local.")
        case .unavailable(.modelNotReady):
            return .needsSetup("O modelo da Apple Intelligence ainda está sendo baixado.")
        case .unavailable(.deviceNotEligible):
            return .unavailable("Este Mac não é compatível com a Apple Intelligence.")
        case .unavailable:
            return .unavailable("O modelo local não está disponível.")
        }
    }

    public func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String] {
        let session = LanguageModelSession(model: model, instructions: PromptBuilder.instructions(for: context))
        do {
            let response = try await session.respond(
                to: PromptBuilder.batchPrompt(lines, context: context),
                generating: Batch.self,
                options: GenerationOptions(temperature: 0.3))
            return Dictionary(response.content.translations.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                throw TranslationEngineError.invalidResponse("lote grande demais para o modelo local")
            case .guardrailViolation, .refusal:
                throw TranslationEngineError.invalidResponse("o modelo local recusou o trecho")
            case .rateLimited, .timeout:
                throw TranslationEngineError.transient("modelo local ocupado")
            case .unsupportedLanguageOrLocale:
                throw TranslationEngineError.permanent("O modelo local não suporta este idioma.")
            default:
                throw TranslationEngineError.permanent(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationEngineError.transient(error.localizedDescription)
        }
    }
}
