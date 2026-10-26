import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Geral", systemImage: "gearshape") { GeneralSettings() }
            Tab("Tradução", systemImage: "translate") { TranslationSettings() }
            Tab("Ferramentas", systemImage: "wrench.and.screwdriver") { ToolSettings() }
            Tab("Sobre", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 620)
        .scenePadding()
    }
}

private let languages: [(String, String)] = [
    ("pt-BR", "Português (Brasil)"), ("pt-PT", "Português (Portugal)"), ("es", "Espanhol"), ("en", "Inglês"),
    ("fr", "Francês"), ("de", "Alemão"), ("it", "Italiano"), ("ja", "Japonês"), ("ko", "Coreano"), ("zh", "Chinês")
]

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Idiomas") {
                Picker("Traduzir para", selection: $app.settings.targetLanguage) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Idioma da legenda original", selection: $app.settings.sourceLanguage) {
                    Text("Detectar automaticamente").tag(String?.none)
                    ForEach(languages, id: \.0) { Text($0.1).tag(Optional($0.0)) }
                }
            }
            Section("Pré-visualização") {
                Toggle("Renderizar ASS fielmente com libass (animações, karaokê, desenhos, fontes do MKV)", isOn: $app.settings.faithfulPreview)
            }
            Section("Revisão") {
                Stepper(value: $app.settings.maxReadingSpeed, in: 10...40, step: 1) {
                    Text("Leitura rápida demais acima de \(Int(app.settings.maxReadingSpeed)) caracteres por segundo")
                }
            }
            Section("Nova faixa no MKV") {
                TextField("Nome da faixa", text: $app.settings.trackName)
                Toggle("Definir como faixa padrão", isOn: $app.settings.makeDefault)
                Toggle("Colocar antes das outras faixas do mesmo tipo", isOn: $app.settings.placeNewTrackFirst)
                Text("O resultado é sempre um arquivo novo ao lado do original (“Nome [PT-BR].mkv”), nunca uma substituição.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranslationSettings: View {
    @Environment(AppModel.self) private var app
    @State private var apiKey = ""
    @State private var keyMessage: String?

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Motor") {
                Picker("Motor de tradução", selection: $app.settings.engine) {
                    ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                }
                Text(app.settings.engine.summary).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $app.settings.contextLines, in: 0...20) { Text("Falas anteriores como contexto: \(app.settings.contextLines)") }
                Toggle("Traduzir linhas de karaokê (perde a sincronia das sílabas)", isOn: $app.settings.translateKaraoke)
            }
            Section {
                Picker("Predefinição", selection: Binding(get: { presetName(app.settings.openAI) }, set: { applyPreset($0) })) {
                    Text("Ollama (local)").tag("ollama")
                    Text("LM Studio (local)").tag("lmstudio")
                    Text("Personalizado").tag("custom")
                }
                TextField("Endereço da API", text: Binding(get: { app.settings.openAI.baseURL.absoluteString },
                                                           set: { if let url = URL(string: $0), url.scheme != nil { app.settings.openAI.baseURL = url } }))
                TextField("Modelo", text: $app.settings.openAI.model)
                Stepper(value: $app.settings.openAI.batchSize, in: 1...100) { Text("Falas por lote: \(app.settings.openAI.batchSize)") }
                HStack {
                    SecureField("Chave de API (opcional para servidores locais)", text: $apiKey)
                    Button("Salvar no Keychain") { saveKey() }
                }
                if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Servidor compatível com OpenAI")
            } footer: {
                Text("A chave fica só no Keychain do macOS e nunca é gravada em arquivos ou registros. Servidores online recebem o texto das legendas; os locais não enviam nada para fora do Mac.")
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = KeychainStore.read(KeychainStore.account(for: app.settings.openAI.baseURL)) ?? "" }
    }

    private func presetName(_ config: OpenAICompatibleEngine.Configuration) -> String {
        if config.baseURL == OpenAICompatibleEngine.Configuration.ollama.baseURL { return "ollama" }
        if config.baseURL == OpenAICompatibleEngine.Configuration.lmStudio.baseURL { return "lmstudio" }
        return "custom"
    }

    private func applyPreset(_ name: String) {
        switch name {
        case "ollama": app.settings.openAI = .ollama
        case "lmstudio": app.settings.openAI = .lmStudio
        default: break
        }
    }

    private func saveKey() {
        do {
            try KeychainStore.write(apiKey, account: KeychainStore.account(for: app.settings.openAI.baseURL))
            keyMessage = apiKey.isEmpty ? "Chave removida." : "Chave salva no Keychain."
        } catch {
            keyMessage = error.localizedDescription
        }
    }
}

private struct ToolSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                ForEach(ExternalTool.allCases) { tool in
                    TextField(tool.rawValue, text: Binding(get: { app.settings.toolPaths[tool.rawValue] ?? "" },
                                                           set: { app.settings.toolPaths[tool.rawValue] = $0.isEmpty ? nil : $0 }),
                              prompt: Text(app.tools.locate(tool)?.path ?? "Não encontrado"))
                }
            } header: {
                Text("Caminhos (deixe vazio para detectar)")
            } footer: {
                Text("Instalação recomendada: brew install mkvtoolnix ffmpeg")
            }
            Section("Dublagem") {
                TextField("Endereço do VoiceStudio", text: Binding(get: { app.settings.voiceStudioURL.absoluteString },
                                                                   set: { if let url = URL(string: $0), url.scheme != nil { app.settings.voiceStudioURL = url } }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Anime Localization Studio").font(.title2.weight(.semibold))
            Text("Versão \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Tradução, edição, dublagem e incorporação de faixas para animes, séries e filmes.")
                .multilineTextAlignment(.center)
            Link("witchmymac.com", destination: URL(string: "https://witchmymac.com")!)
            Text("Usa libass (ISC) e suas bibliotecas, FluidAudio (Apache-2.0) e modelos de identificação de falantes de pyannote, WeSpeaker e BUT Speech@FIT (CC-BY-4.0, conversão da Fluid Inference). MKVToolNix (GPL-2.0) e FFmpeg são programas externos, e o VoiceStudio (AGPL-3.0) é um serviço local separado. Licenças completas em Contents/Resources/Licenses e THIRD_PARTY_NOTICES.md.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}
