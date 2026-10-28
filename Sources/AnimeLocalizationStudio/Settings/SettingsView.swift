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
            Tab("Armazenamento", systemImage: "internaldrive") { StorageSettings() }
            Tab("Diagnóstico", systemImage: "stethoscope") { DiagnosticsView() }
            Tab("Sobre", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 660, height: 560)
        .scenePadding()
    }
}

private let languages = Languages.all.map { ($0.code, $0.name) }

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
                Text("Antes de gravar, o app sempre pergunta: um arquivo novo ao lado do original (“Nome [PT-BR].mkv”) ou o próprio arquivo.")
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
            Section {
                ElevenLabsAccountView()
            } header: {
                Text("Dublagem online (ElevenLabs)")
            } footer: {
                Text("A chave fica só no Keychain do macOS. Cada dublagem usa créditos da sua conta.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Sobre, in the MacDash pattern of every witchmymac app: icon, name, version, what the app
/// does, its license, the site, “Licenças e créditos” and the update check.
private struct AboutSettings: View {
    @State private var showCredits = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Versão \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .padding(.bottom, 18)
                Text("Anime Localization Studio")
                    .font(.system(size: 24, weight: .semibold))
                Text(version)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                Text("Corrija, traduza e duble legendas de animes, séries e filmes direto no MKV: estilos, tags, posições e karaokê preservados, tradução com motores no Mac ou o seu servidor, legenda criada a partir do áudio e dublagem com a voz de cada personagem. O vídeo nunca é recodificado e o arquivo original só muda se você pedir.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
                    .padding(.top, 26)
                Text("Anime Localization Studio é software livre sob a GNU GPL v3.0. Usa os projetos de código aberto listados nas licenças.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.top, 14)
                HStack(spacing: 18) {
                    Link("witchmymac.com", destination: URL(string: "http://witchmymac.com")!)
                        .font(.system(size: 12))
                        .hint("witchmymac.com", "Abre o site com os apps do witchmymac.")
                    Button("Licenças e créditos") { showCredits = true }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .hint("Licenças e créditos", "Os projetos de código aberto, modelos, programas e serviços que o app usa, com as licenças.")
                    Link("Código-fonte", destination: URL(string: "https://github.com/matthfaria96/anime-localization-studio")!)
                        .font(.system(size: 12))
                        .hint("Código-fonte", "Abre o repositório do app no GitHub.")
                }
                .padding(.top, 10)
                CheckForUpdatesButton()
                    .controlSize(.small)
                    .padding(.top, 14)
                    .hint("Verificar atualizações", "Procura agora uma versão nova. O app também verifica sozinho uma vez por dia e pergunta antes de instalar.")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showCredits) { CreditsView() }
    }
}

/// What the app includes, downloads, runs or talks to, with each license.
private struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Credit: Identifiable {
        let name: String
        let detail: String
        let link: String
        var id: String { name }
    }

    private struct Group: Identifiable {
        let title: String
        let credits: [Credit]
        var id: String { title }
    }

    private let groups = [
        Group(title: "Dentro do app", credits: [
            Credit(name: "libass", detail: "Desenha as legendas ASS como no player (animações, karaokê, desenhos, fontes). ISC. Com FreeType (FTL), HarfBuzz (MIT), FriBidi e GLib (LGPL-2.1), libunibreak (Zlib), PCRE2 (BSD-3), Graphite2, libpng e Brotli.", link: "https://github.com/libass/libass"),
            Credit(name: "FluidAudio", detail: "Identifica quem fala (diarização) no Neural Engine. Apache-2.0, Fluid Inference.", link: "https://github.com/FluidInference/FluidAudio"),
            Credit(name: "speech-swift", detail: "Roda o Chatterbox no Mac (voz clonada da dublagem). Apache-2.0, soniqo.", link: "https://github.com/soniqo/speech-swift"),
            Credit(name: "MLX e mlx-swift", detail: "Cálculo na GPU do Apple silicon para a voz. MIT, Apple.", link: "https://github.com/ml-explore/mlx-swift"),
            Credit(name: "swift-transformers", detail: "Tokenizadores e download de modelos. Apache-2.0, Hugging Face.", link: "https://github.com/huggingface/swift-transformers"),
            Credit(name: "Sparkle", detail: "Atualizações dentro do app. MIT, Andy Matuschak e colaboradores.", link: "https://github.com/sparkle-project/Sparkle"),
        ]),
        Group(title: "Modelos baixados quando você pede", credits: [
            Credit(name: "Chatterbox Multilingual", detail: "Voz clonada de cada personagem, em 23 idiomas. MIT, Resemble AI.", link: "https://github.com/resemble-ai/chatterbox"),
            Credit(name: "pyannote, WeSpeaker e BUT Speech@FIT", detail: "Modelos de identificação de falantes, convertidos para Core ML pela Fluid Inference. CC-BY-4.0.", link: "https://huggingface.co/FluidInference/speaker-diarization-coreml"),
        ]),
        Group(title: "Programas e serviços usados", credits: [
            Credit(name: "MKVToolNix", detail: "Lê e grava o MKV sem recodificar (mkvmerge, mkvextract, mkvpropedit). GPL-2.0, Moritz Bunkus. Instalado à parte.", link: "https://mkvtoolnix.download"),
            Credit(name: "FFmpeg", detail: "Pré-visualização, extração e mixagem de áudio. LGPL/GPL. Instalado à parte.", link: "https://ffmpeg.org"),
            Credit(name: "ElevenLabs", detail: "Dublagem online opcional, com a sua conta e a sua chave. Serviço externo; nenhum código incluído.", link: "https://elevenlabs.io"),
            Credit(name: "Apple", detail: "Tradução, Apple Intelligence, reconhecimento de fala e de texto (OCR) do próprio macOS.", link: "https://developer.apple.com"),
            Credit(name: "Aegisub", detail: "Referência para o formato ASS e para marcar karaokê no tempo. Nenhum código incluído.", link: "https://github.com/Aegisub/Aegisub"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Licenças e créditos")
                .font(.system(size: 17, weight: .semibold))
                .padding(.bottom, 4)
            Text("Os textos completos das licenças estão em Contents/Resources/Licenses, dentro do app, e em THIRD_PARTY_NOTICES.md no código-fonte.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                            .padding(.top, 12).padding(.bottom, 2)
                        ForEach(group.credits) { credit in
                            VStack(alignment: .leading, spacing: 3) {
                                Link(credit.name, destination: URL(string: credit.link)!)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(credit.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 480, height: 560)
    }
}
