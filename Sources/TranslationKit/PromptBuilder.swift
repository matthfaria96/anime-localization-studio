import Foundation

/// Instructions and batch prompts shared by the language-model engines.
enum PromptBuilder {
    static func languageName(_ code: String?) -> String {
        guard let code else { return "o idioma de origem (detecte-o)" }
        let locale = Locale(identifier: "pt_BR")
        return locale.localizedString(forIdentifier: code) ?? code
    }

    static func instructions(for context: TranslationContext) -> String {
        var text = """
        Você é um tradutor profissional de legendas de anime, séries e filmes para \(languageName(context.targetLanguage)).
        Traduza cada fala de \(languageName(context.sourceLanguage)) de forma natural, fiel ao tom e à personalidade de quem fala, \
        com frases curtas que caibam na tela. Quando o original for coloquial, use a linguagem coloquial natural de \(languageName(context.targetLanguage)).
        Regras obrigatórias:
        - Responda somente com a tradução de cada id recebido, sem comentários.
        - Mantenha cada marcador ⟦n⟧ exatamente como está, uma vez cada, junto à palavra correspondente.
        - Não junte nem divida falas: um id de entrada, um id de saída.
        - Mantenha nomes próprios, a menos que o glossário diga outra coisa.
        """
        text += context.keepHonorifics
            ? "\n- Mantenha honoríficos japoneses (-san, -kun, -chan, -sama, -senpai, -sensei) como no original."
            : "\n- Adapte honoríficos japoneses para formas naturais em \(languageName(context.targetLanguage)) ou omita-os."
        if !context.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\nNotas da obra:\n\(context.notes)"
        }
        return text
    }

    static func batchPrompt(_ lines: [TranslationLine], context: TranslationContext) -> String {
        var prompt = ""
        if !context.glossary.isEmpty {
            prompt += "Glossário obrigatório (origem → tradução):\n"
            for entry in context.glossary {
                prompt += "- \(entry.source) → \(entry.target)\(entry.note.isEmpty ? "" : " (\(entry.note))")\n"
            }
            prompt += "\n"
        }
        if !context.previousLines.isEmpty {
            prompt += "Falas anteriores, já traduzidas (apenas contexto, não traduza de novo):\n"
            for line in context.previousLines {
                prompt += "\(line.speaker.map { "[\($0)] " } ?? "")\(line.source) => \(line.translation)\n"
            }
            prompt += "\n"
        }
        prompt += "Traduza estas falas:\n"
        for line in lines {
            prompt += "\(line.id)\t\(line.speaker.map { "[\($0)] " } ?? "")\(line.text)\n"
        }
        return prompt
    }

    /// `{"translations":[{"id":1,"text":"…"}]}`, tolerating code fences or text around the JSON.
    static func parseJSONTranslations(_ content: String) throws -> [Int: String] {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") else {
            throw TranslationEngineError.invalidResponse("sem JSON na resposta")
        }
        struct Payload: Decodable {
            struct Item: Decodable {
                let id: Int
                let text: String
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    if let n = try? c.decode(Int.self, forKey: .id) { id = n } else {
                        guard let n = Int(try c.decode(String.self, forKey: .id)) else {
                            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id")
                        }
                        id = n
                    }
                    text = try c.decode(String.self, forKey: .text)
                }
                enum CodingKeys: String, CodingKey { case id, text }
            }
            let translations: [Item]
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(content[start...end].utf8))
            return Dictionary(payload.translations.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        } catch {
            throw TranslationEngineError.invalidResponse("JSON fora do formato esperado")
        }
    }
}
