import AVFoundation
import DubbingKit
import MediaKit
import StudioCore
import SubtitleKit
import SwiftUI

/// Automatic dub: the app finds who speaks, recreates each character's voice (a clone of the
/// original with VoiceStudio, or a macOS voice of similar pitch) and dubs the whole episode.
/// Choosing voices by hand is optional.
struct DubbingView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var studioConnected: Bool?
    @State private var studioVoices: [VoiceStudioClient.Voice] = []
    @State private var cast = VoiceCast()
    @State private var sampleState: [UUID: String] = [:]
    @State private var audioPlayer: AVAudioPlayer?
    @State private var showManualVoices = false

    private var segments: [DubSegment] {
        guard let document = workspace.editor.translation ?? workspace.editor.source else { return [] }
        return DubbingPlan.segments(from: document)
    }
    private var isTranslated: Bool { workspace.editor.translation != nil }
    private var usesClones: Bool { app.settings.dubbingEngine == .voiceStudio }
    private var engineReady: Bool { !usesClones || studioConnected == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Dublagem").font(.largeTitle.weight(.semibold))
                    Text("Um clique: o app descobre quem fala, recria a voz de cada personagem e dubla o episódio inteiro em português.")
                        .foregroundStyle(.secondary)
                }
                if let operation = workspace.operation {
                    OperationProgress(message: operation.message, fraction: operation.fraction) { workspace.cancelOperation() }
                }
                if let notice = workspace.notice {
                    InlineMessage(kind: notice.kind, text: notice.text)
                    if let action = workspace.noticeAction { Button(action.title, action: action.run).buttonStyle(.link) }
                }
                howPanel
                castPanel
                if let dub = workspace.lastDub { resultPanel(dub) }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .task {
            cast = workspace.loadCast()
            rebuildCast()
            await checkStudio()
        }
        .onChange(of: app.settings.dubbingEngine) { Task { await checkStudio() } }
        .onChange(of: workspace.editor.revision) { rebuildCast() }
        .onChange(of: cast) { _, new in workspace.saveCast(new) }
        .modifier(SpeakerModelConsent(workspace: workspace))
        .sheet(isPresented: Binding(get: { workspace.dubSession != nil }, set: { if !$0 && !isDubRunning { workspace.dubSession = nil } })) {
            DubSessionSheet(workspace: workspace, cast: $cast, studioConnected: studioConnected, segmentCount: segments.count)
        }
    }

    private var isDubRunning: Bool { if case .running = workspace.dubSession?.phase { true } else { false } }

    // MARK: How to dub

    private var howPanel: some View {
        @Bindable var app = app
        return Panel {
            SectionLabel("Vozes", systemImage: "waveform.badge.mic")
            HStack(spacing: Theme.Spacing.m) {
                OptionCard(title: "Voz original clonada", systemImage: "person.wave.2.fill",
                           detail: studioStatus, selected: usesClones) { app.settings.dubbingEngine = .voiceStudio }
                    .hint("Voz original clonada", "Cada personagem fala português com a própria voz do episódio: o app tira um trecho da voz original e o VoiceStudio cria uma cópia dela. Precisa do VoiceStudio aberto (app gratuito, instalado à parte). Clone apenas vozes que você tem permissão de usar.")
                OptionCard(title: "Vozes do macOS", systemImage: "desktopcomputer",
                           detail: "Prontas, robóticas. O app escolhe uma voz grave ou aguda parecida com a original.", selected: !usesClones) {
                    app.settings.dubbingEngine = .system
                }
                .hint("Vozes do macOS", "Usa as vozes do sistema, sem instalar nada. O app mede se a voz original é grave ou aguda e escolhe uma voz parecida e diferente para cada personagem. Servem para rascunho e conferência de tempo.")
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
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isTranslated ? "\(segments.count) falas para dublar" : "Traduza o episódio antes de dublar")
                        .font(.headline)
                    Text("Antes de começar você escolhe onde gravar: um novo arquivo ou o próprio arquivo. O áudio e as legendas originais são mantidos.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    workspace.startDubSession()
                } label: {
                    Label("Dublar episódio inteiro", systemImage: "waveform")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!isTranslated || segments.isEmpty || workspace.isBusy)
                .hintVerbatim("Dublar episódio inteiro", isTranslated
                    ? "Abre uma janela que mostra o que vai acontecer e pergunta onde gravar (novo arquivo ou o próprio). Depois faz tudo sozinho e mostra o resultado."
                    : "A dublagem usa o texto traduzido. Traduza o episódio na aba Legendas primeiro.")
            }
            .padding(.top, Theme.Spacing.s)
        }
    }

    private var studioStatus: String {
        switch studioConnected {
        case .none: "Procurando o VoiceStudio…"
        case .some(true): "VoiceStudio conectado. Fala português com a voz de cada personagem."
        case .some(false): "Precisa do VoiceStudio aberto (voicestudio.sh). Não encontrado neste Mac."
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
            if cast.members.isEmpty {
                Text(workspace.editor.hasDocument
                     ? "A legenda ainda não diz quem fala. Ao dublar, o app identifica os falantes pelo áudio; ou clique em “Identificar falantes no áudio” para ver e renomear antes."
                     : "Abra uma legenda para começar.")
                    .foregroundStyle(.secondary)
            }
            ForEach($cast.members) { $member in castRow($member) }
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
                Text("\(lines.count) falas").font(.caption).foregroundStyle(.secondary)
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
        return usesClones ? "Voz original clonada" : "Voz \(voice)"
    }

    // MARK: Result

    private func resultPanel(_ dub: (url: URL, report: DubbingReport, verification: VerificationReport)) -> some View {
        Panel {
            HStack {
                SectionLabel("Última dublagem", systemImage: "checkmark.seal")
                Spacer()
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([dub.url]) }
                    .buttonStyle(.link)
                    .hint("Mostrar no Finder", "Abre a pasta do arquivo dublado com ele selecionado.")
            }
            let r = dub.report
            Text("\(r.synthesized) falas geradas, \(r.reusedClips) reaproveitadas · \(r.spedUp.count) aceleradas · \(r.overflowing.count) ainda longas · \(r.delayed.count) atrasadas para não sobrepor · \(r.failed.count) sem voz")
                .font(.callout)
            let problems = r.problemLines.sorted()
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Para revisar").font(.caption.weight(.semibold))
                    ForEach(problems.prefix(12), id: \.self) { id in
                        Button("Fala \(id + 1): \(segments.first { $0.id == id }?.text ?? "")") { workspace.select(id, seek: true) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .hint("Ir para a fala", "Mostra esta fala no vídeo e no editor. Edite a tradução e dublar de novo refaz só as falas alteradas.")
                    }
                }
            }
            VerificationList(report: dub.verification)
        }
    }

    // MARK: Actions

    private func checkStudio() async {
        guard usesClones else { return }
        studioConnected = nil
        let client = VoiceStudioClient(baseURL: app.settings.voiceStudioURL)
        do {
            _ = try await client.capabilities()
            studioVoices = try await client.voices()
            studioConnected = true
        } catch {
            studioConnected = false
        }
    }

    private func rebuildCast() {
        cast.addMissing(from: DubbingPlan.speakers(in: segments).filter { $0 != "Desconhecido" })
    }

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
            try await app.settings.makeSynthesizer().synthesize(line ?? "Olá! Esta é uma amostra da minha voz.", voice: voice,
                                                                 style: member.style.isEmpty ? nil : member.style, speed: member.speed, to: file)
            audioPlayer = try AVAudioPlayer(data: Data(contentsOf: file))
            audioPlayer?.play()
            sampleState[member.id] = nil
        } catch {
            sampleState[member.id] = error.localizedDescription
        }
    }
}

/// A large selectable choice with its own explanation (unlike a segmented control, each
/// option can carry its own hover hint).
private struct OptionCard: View {
    let title: String
    let systemImage: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: systemImage).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.background.secondary),
                        in: .rect(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
