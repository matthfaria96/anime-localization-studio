import AVFoundation
import DubbingKit
import StudioCore
import SwiftUI

/// The part of Dublar that most people never need: which engine makes the voices, how they
/// are mixed, and each character's voice. Collapsed by default.
struct DubVoicesSection: View {
    @Bindable var workspace: WorkspaceModel
    let studioConnected: Bool?
    let studioVoices: [VoiceStudioClient.Voice]
    let checkStudio: () async -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var sampleState: [UUID: String] = [:]
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showManualVoices = false

    private var segments: [DubSegment] { workspace.dubSegments }
    private var usesClones: Bool { app.settings.dubbingEngine == .voiceStudio }
    private var engineReady: Bool { !usesClones || studioConnected == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            enginePanel
            castPanel
        }
    }

    private var enginePanel: some View {
        @Bindable var app = app
        return Panel {
            SectionLabel("Vozes", systemImage: "waveform.badge.mic")
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                OptionCard(title: "Voz original (no Mac)", systemImage: "person.wave.2.fill",
                           detail: !ClonedVoiceSynthesizer.supports(app.settings.targetLanguage)
                               ? "Ainda não fala \(Languages.name(for: app.settings.targetLanguage)). Fala português, espanhol, inglês, francês, alemão e italiano."
                               : workspace.voiceModelsInstalled ? "Recomendado. Cada personagem fala \(Languages.name(for: app.settings.targetLanguage)) com a própria voz do vídeo."
                                                                : "Recomendado. Cada personagem fala com a própria voz do vídeo. Na primeira vez baixa \(ClonedVoiceSynthesizer.downloadSize) para o idioma.",
                           selected: app.settings.dubbingEngine == .original) { app.settings.dubbingEngine = .original }
                    .hint("Voz original (no Mac)", "O app separa a voz de cada personagem do áudio original e a recria falando o idioma da legenda, tudo no próprio Mac (Pocket TTS da Kyutai, licença CC-BY-4.0). Não é tradução de fala para fala e a boca não acompanha. Clone apenas vozes que você tem permissão de usar.")
                OptionCard(title: "Vozes do macOS", systemImage: "desktopcomputer",
                           detail: "Rascunho rápido: vozes prontas do sistema, robóticas.", selected: app.settings.dubbingEngine == .system) {
                    app.settings.dubbingEngine = .system
                }
                .hint("Vozes do macOS", "Usa as vozes do sistema, escolhidas pelo tom de cada personagem. São robóticas: servem para conferir tempo e texto rapidamente.")
                ZStack(alignment: .topTrailing) {
                    OptionCard(title: "VoiceStudio", systemImage: "server.rack", detail: studioStatus, selected: app.settings.dubbingEngine == .voiceStudio) {
                        app.settings.dubbingEngine = .voiceStudio
                    }
                    Button { Task { await checkStudio() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .padding(Theme.Spacing.s)
                        .hint("Procurar o VoiceStudio", "Verifica de novo se o VoiceStudio está aberto neste Mac.")
                }
                .hint("VoiceStudio", "Usa o VoiceStudio (app gratuito instalado à parte) para clonar as vozes. Útil se você já tem vozes prontas nele.")
            }
            if app.settings.dubbingEngine == .original {
                @Bindable var app = app
                Toggle(isOn: $app.settings.dubbingPerLineVoice) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voz e emoção de cada fala")
                        Text(app.settings.dubbingPerLineVoice
                             ? "Cada fala é recriada a partir do próprio trecho original: mesma voz e mesma emoção (grito, sussurro…). Falas com menos de 1,5 s usam a amostra do personagem."
                             : "Uma amostra de ~12 s por personagem: voz estável, mas sem a emoção de cada fala.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .hint("Voz e emoção de cada fala", "Ligado (recomendado): o trecho japonês de cada fala, sem a música, serve de referência para a mesma fala dublada. Desligado: uma amostra fixa por personagem.")
            }
            SectionLabel("Modo", systemImage: "slider.horizontal.3")
            HStack(spacing: Theme.Spacing.m) {
                OptionCard(title: "Substituir falas", systemImage: "person.2.slash",
                           detail: "As vozes originais saem e as novas entram no lugar, com a música e os efeitos.",
                           selected: app.settings.dubbingMode == .replaceDialogue) { app.settings.dubbingMode = .replaceDialogue }
                    .hint("Substituir falas", "Como uma dublagem de TV: o app separa as vozes originais da música e dos efeitos, tira as vozes e coloca as dubladas no lugar. A separação é feita no Mac e é aproximada: em cenas com muita música podem sobrar restos da voz original.")
                OptionCard(title: "Voice-over", systemImage: "person.2.wave.2",
                           detail: "A voz nova fala por cima; o áudio original abaixa enquanto ela fala.",
                           selected: app.settings.dubbingMode == .voiceOver) { app.settings.dubbingMode = .voiceOver }
                    .hint("Voice-over", "Como em documentários: o áudio original continua, só que mais baixo enquanto a voz em português fala por cima.")
            }
        }
    }

    private var studioStatus: String {
        switch studioConnected {
        case .none: "Procurando o VoiceStudio…"
        case .some(true): "Conectado."
        case .some(false): "Não está aberto neste Mac. Abra-o e clique em ↻."
        }
    }

    // MARK: Cast

    private var castPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                SectionLabel("Personagens", systemImage: "person.2")
                Spacer()
                Button("Identificar falantes no áudio", systemImage: "person.wave.2") { workspace.identifySpeakers(undoManager: undoManager) }
                    .disabled(workspace.isBusy || !workspace.editor.hasDocument || workspace.audioTracks.isEmpty)
                    .hint("Identificar falantes no áudio", "Descobre pelo áudio quem fala em cada linha sem personagem e preenche “Falante 1”, “Falante 2”… Tudo no Mac. ⌘Z desfaz. A dublagem automática faz isso sozinha quando precisa.")
                Toggle("Escolher vozes manualmente", isOn: $showManualVoices)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .hint("Escolher vozes manualmente", "Mostra a escolha de voz de cada personagem. Desligado, o app escolhe sozinho ao dublar.")
            }
            if workspace.cast.members.isEmpty {
                Text(workspace.editor.hasDocument
                     ? "A legenda ainda não diz quem fala. Ao dublar, o app identifica os falantes pelo áudio; ou clique em “Identificar falantes no áudio” para ver e renomear antes."
                     : "Abra uma legenda para começar.")
                    .foregroundStyle(.secondary)
            }
            ForEach($workspace.cast.members) { $member in castRow($member) }
        }
    }

    private func castRow(_ member: Binding<CastMember>) -> some View {
        let name = member.wrappedValue.name
        let lines = segments.filter { $0.speaker == name }
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.tint.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                CastNameField(name: name) { newName in
                    workspace.editor.renameActor(name, to: newName, undoManager: undoManager)
                    member.wrappedValue.name = newName
                }
                Text(Plural.count(lines.count, "fala", "falas")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 170, alignment: .leading)
            Button("Ouvir original", systemImage: "ear") { Task { await playOriginal(name) } }
                .disabled(workspace.isBusy && workspace.voiceSamples.isEmpty)
                .hint("Ouvir a voz original", "Toca um trecho da voz deste personagem no episódio, sem a música, para você saber quem é.")
            if showManualVoices {
                Picker("Voz", selection: member.voiceID) {
                    Text("Automática").tag(String?.none)
                    ForEach(voiceOptions, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 220)
                .hint("Voz", "Voz que dubla este personagem. “Automática” deixa o app escolher (ou clonar a original) ao dublar.")
                Stepper(value: member.speed, in: 0.7...1.5, step: 0.05) {
                    Text(member.wrappedValue.speed, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 34)
                }
                .hint("Velocidade", "Deixa a voz deste personagem mais lenta (abaixo de 1) ou mais rápida (acima de 1).")
            } else {
                Text(voiceLabel(member.wrappedValue)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .hint("Voz", "Escolhida pelo app ao dublar. Ligue “Escolher vozes manualmente” para trocar.")
            }
            Spacer()
            Button("Ouvir dublada", systemImage: "play.circle") { Task { await sample(member.wrappedValue, line: lines.first?.text) } }
                .disabled(member.wrappedValue.voiceID == nil || !engineReady)
                .hint("Ouvir dublada", "Toca uma fala deste personagem em português com a voz escolhida. Depois da primeira dublagem automática, toca a voz que o app escolheu.")
            if let state = sampleState[member.wrappedValue.id] { Text(state).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(Theme.Spacing.s)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
    }

    private struct VoiceOption: Hashable { let id: String; let name: String }

    private var voiceOptions: [VoiceOption] {
        if usesClones { return studioVoices.map { VoiceOption(id: $0.voice_id, name: $0.name) } }
        let prefix = String(app.settings.targetLanguage.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }.map { VoiceOption(id: $0.name, name: $0.name) }
    }

    private func voiceLabel(_ member: CastMember) -> String {
        guard let voice = member.voiceID, member.engine == app.settings.dubbingEngine.rawValue || member.engine == nil else { return "Automática" }
        switch app.settings.dubbingEngine {
        case .original: return "Voz original"
        case .voiceStudio: return "Voz clonada (VoiceStudio)"
        case .system: return "Voz \(voice)"
        }
    }


    // MARK: Listening

    private func playOriginal(_ speaker: String) async {
        if workspace.voiceSamples[speaker] == nil { await workspace.prepareVoiceSamples() }
        guard let url = workspace.voiceSamples[speaker], let data = try? Data(contentsOf: url) else { return }
        audioPlayer = try? AVAudioPlayer(data: data)
        audioPlayer?.play()
    }

    private func sample(_ member: CastMember, line: String?) async {
        guard let voice = member.voiceID else { return }
        sampleState[member.id] = "Gerando…"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("als-sample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await app.settings.makeSynthesizer(paths: app.paths).synthesize(line ?? "Olá! Esta é uma amostra da minha voz.", voice: voice,
                                                                 style: member.style.isEmpty ? nil : member.style, speed: member.speed, to: file)
            audioPlayer = try AVAudioPlayer(data: Data(contentsOf: file))
            audioPlayer?.play()
            sampleState[member.id] = nil
        } catch {
            sampleState[member.id] = error.localizedDescription
        }
    }
}

/// Character name that renames every line of that character when edited (Return to apply).
private struct CastNameField: View {
    let name: String
    let rename: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("Personagem", text: $draft)
            .textFieldStyle(.plain)
            .font(.headline)
            .onAppear { draft = name }
            .onChange(of: name) { draft = name }
            .onSubmit { if draft != name { rename(draft) } }
            .hint("Nome do personagem", "Digite o nome e aperte Return (ex.: Falante 1 → Kirito). Todas as falas desse falante passam a usar o nome.")
    }
}
