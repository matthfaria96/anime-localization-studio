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
    @State private var recordToDelete: DubRecord?
    @State private var confirmClearFiles = false

    private var segments: [DubSegment] {
        guard let document = workspace.editor.translation ?? workspace.editor.source else { return [] }
        return DubbingPlan.segments(from: document)
    }
    private var isTranslated: Bool { workspace.editor.translation != nil }
    private var usesClones: Bool { app.settings.dubbingEngine == .voiceStudio }
    private var engineReadyLabel: Bool { engineReady }
    private var engineReady: Bool { !usesClones || studioConnected == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Dublagem").font(.largeTitle.weight(.semibold))
                    Text("O app lê em voz alta a legenda traduzida, no tempo de cada fala, com a voz de cada personagem recriada a partir do áudio original.")
                        .foregroundStyle(.secondary)
                }
                if let operation = workspace.operation {
                    OperationProgress(message: operation.message, fraction: operation.fraction) { workspace.cancelOperation() }
                }
                if let notice = workspace.notice {
                    InlineMessage(kind: notice.kind, text: notice.text)
                    if let action = workspace.noticeAction { Button(action.title, action: action.run).buttonStyle(.link) }
                }
                sourcePanel
                howPanel
                castPanel
                if let dub = workspace.lastDub { resultPanel(dub) }
                historyPanel
                storagePanel
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .task {
            workspace.refreshDubStorage()
            cast = workspace.loadCast()
            rebuildCast()
            await checkStudio(force: true)
        }
        .onChange(of: workspace.editor.revision) { rebuildCast() }
        .onChange(of: cast) { _, new in workspace.saveCast(new) }
        .modifier(SpeakerModelConsent(workspace: workspace))
        .confirmationDialog("Apagar os arquivos guardados desta dublagem?", isPresented: $confirmClearFiles) {
            Button("Apagar", role: .destructive) { workspace.clearDubFiles() }
        } message: {
            Text("As falas geradas, as vozes separadas e a música de fundo deste episódio são apagadas (\(ByteCountFormatter.string(fromByteCount: workspace.dubStorageBytes, countStyle: .file))). A próxima dublagem gera tudo do zero. Os vídeos já dublados não são apagados.")
        }
        .confirmationDialog("Apagar esta dublagem?", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
                            presenting: recordToDelete) { record in
            if workspace.canTrashOutput(of: record) {
                Button("Apagar o arquivo e tirar do histórico", role: .destructive) { workspace.deleteDubRecord(record, trashFile: true) }
            }
            Button("Só tirar do histórico") { workspace.deleteDubRecord(record, trashFile: false) }
        } message: { record in
            Text(workspace.canTrashOutput(of: record)
                 ? "“\(record.outputURL.lastPathComponent)” vai para a Lixeira (dá para recuperar de lá). Ou tire só do histórico e mantenha o arquivo."
                 : record.replacedOriginal
                    ? "Esta dublagem foi gravada no próprio arquivo, que não é apagado aqui. Ela sai só do histórico."
                    : "O arquivo não está mais no disco ou é o vídeo aberto agora. A dublagem sai só do histórico.")
        }
        .sheet(isPresented: Binding(get: { workspace.dubSession != nil }, set: { if !$0 && !isDubRunning { workspace.dubSession = nil } })) {
            DubSessionSheet(workspace: workspace, cast: $cast, studioConnected: studioConnected, segmentCount: segments.count)
        }
    }

    private var isDubRunning: Bool { if case .running = workspace.dubSession?.phase { true } else { false } }

    // MARK: What is dubbed

    private var targetName: String {
        Locale.current.localizedString(forIdentifier: app.settings.targetLanguage) ?? app.settings.targetLanguage
    }

    private var sourcePanel: some View {
        Panel {
            SectionLabel("O que vai ser dublado", systemImage: "arrow.triangle.branch")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.l, verticalSpacing: Theme.Spacing.m) {
                GridRow {
                    Label("Áudio de base", systemImage: "waveform").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if workspace.audioTracks.count > 1 {
                            Picker("Áudio de base", selection: Binding(get: { workspace.dubAudioTrack?.id ?? -1 }, set: { workspace.selectDubAudio($0) })) {
                                ForEach(workspace.audioTracks) { Text(WorkspaceModel.describe($0)).tag($0.id) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(workspace.isBusy)
                            .hint("Áudio de base", "A faixa de onde saem as vozes originais (para recriar cada personagem) e a música e os efeitos que ficam por baixo. Trocar apaga as vozes e o fundo já preparados desta dublagem.")
                        } else {
                            Text(workspace.dubAudioTrack.map(WorkspaceModel.describe) ?? "O arquivo não tem áudio")
                        }
                        Text("As vozes dos personagens e a música e os efeitos saem desta faixa. Use o áudio no idioma original (geralmente o japonês).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Label("Texto falado", systemImage: "text.bubble").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if isTranslated {
                            Text("A legenda traduzida para \(targetName): \(segments.count) falas")
                        } else {
                            HStack {
                                Text("Ainda não há legenda traduzida.")
                                Button("Ir para Legendar") { app.show(.subtitles) }
                                    .buttonStyle(.link)
                                    .hint("Ir para Legendar", "Crie a tradução lá; ela é o texto que a dublagem fala.")
                            }
                        }
                        Text("O áudio não é interpretado nem traduzido: o app fala o texto da tradução, no tempo de cada fala. Corrigir a tradução muda o que é dito.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Label("Resultado", systemImage: "square.and.arrow.down").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uma nova faixa de áudio em \(targetName), marcada como padrão")
                        Text("O áudio original e as legendas continuam no arquivo. Antes de começar você escolhe entre um novo arquivo e o próprio arquivo.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: History

    private var historyPanel: some View {
        Panel {
            SectionLabel("Histórico de dublagens", systemImage: "clock.arrow.circlepath")
            if workspace.dubHistory.isEmpty {
                Text("Nenhuma dublagem feita deste vídeo ainda. Cada dublagem terminada aparece aqui, com o arquivo onde foi gravada.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(workspace.dubHistory) { record in historyRow(record) }
        }
    }

    private func historyRow(_ record: DubRecord) -> some View {
        let exists = FileManager.default.fileExists(atPath: record.outputPath)
        return HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: record.verified && record.failedLines == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(record.verified && record.failedLines == 0 ? Theme.translated : Theme.warning)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(record.outputURL.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if record.replacedOriginal { Tag(text: "Próprio arquivo") }
                    if !exists { Tag(text: "Arquivo não encontrado", tint: Theme.warning) }
                }
                Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text("\(record.engine) · \(record.mode) · áudio \(record.baseAudio) · \(record.lines) falas\(record.failedLines > 0 ? " (\(record.failedLines) sem voz)" : "") · \(record.language)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.s)
            if exists {
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([record.outputURL]) }
                    .labelStyle(.iconOnly)
                    .hint("Mostrar no Finder", "Abre a pasta do arquivo dublado com ele selecionado.")
            }
            Button("Apagar…", systemImage: "trash") { recordToDelete = record }
                .labelStyle(.iconOnly)
                .disabled(workspace.isBusy)
                .hint("Apagar esta dublagem", "Pergunta antes: tirar só do histórico ou também mandar o arquivo dublado para a Lixeira.")
        }
        .padding(Theme.Spacing.s)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
    }

    // MARK: Stored files

    private var storagePanel: some View {
        Panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Arquivos guardados desta dublagem", systemImage: "internaldrive")
                    Text(workspace.dubStorageBytes > 0
                         ? "\(ByteCountFormatter.string(fromByteCount: workspace.dubStorageBytes, countStyle: .file)) em falas geradas, vozes separadas e música de fundo. Eles deixam a próxima dublagem mais rápida: só o que mudou é gerado de novo."
                         : "Nada guardado ainda. As falas geradas ficam aqui para a próxima dublagem ser mais rápida.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Apagar…", systemImage: "trash") { confirmClearFiles = true }
                    .disabled(workspace.dubStorageBytes == 0 || workspace.isBusy)
                    .hint("Apagar os arquivos desta dublagem", "Pergunta antes de apagar. Libera o espaço; a próxima dublagem gera tudo do zero. Os vídeos já dublados não são apagados. Para ver tudo o que o app guarda, abra Ajustes › Armazenamento.")
            }
        }
    }

    // MARK: How to dub

    private var howPanel: some View {
        @Bindable var app = app
        return Panel {
            SectionLabel("Vozes", systemImage: "waveform.badge.mic")
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                OptionCard(title: "Voz original (no Mac)", systemImage: "person.wave.2.fill",
                           detail: workspace.voiceModelsInstalled ? "Recomendado. Cada personagem fala português com a própria voz do episódio. Modelos instalados."
                                                                  : "Recomendado. Cada personagem fala português com a própria voz. Na primeira vez baixa \(ClonedVoiceSynthesizer.downloadSize).",
                           selected: app.settings.dubbingEngine == .original) { app.settings.dubbingEngine = .original }
                    .hint("Voz original (no Mac)", "O app tira um trecho da voz de cada personagem no episódio e a recria falando português, tudo no próprio Mac (Pocket TTS da Kyutai, licença CC-BY-4.0). Não precisa instalar outro programa. Clone apenas vozes que você tem permissão de usar.")
                OptionCard(title: "Vozes do macOS", systemImage: "desktopcomputer",
                           detail: "Rascunho rápido: vozes prontas do sistema, robóticas.", selected: app.settings.dubbingEngine == .system) {
                    app.settings.dubbingEngine = .system
                }
                .hint("Vozes do macOS", "Usa as vozes do sistema, escolhidas pelo tom de cada personagem. São robóticas: servem para conferir tempo e texto rapidamente.")
                ZStack(alignment: .topTrailing) {
                    OptionCard(title: "VoiceStudio", systemImage: "server.rack", detail: studioStatus, selected: app.settings.dubbingEngine == .voiceStudio) {
                        app.settings.dubbingEngine = .voiceStudio
                    }
                    Button { Task { await checkStudio(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .padding(Theme.Spacing.s)
                        .hint("Procurar o VoiceStudio", "Verifica de novo se o VoiceStudio está aberto neste Mac.")
                }
                .hint("VoiceStudio", "Usa o VoiceStudio (app gratuito instalado à parte) para clonar as vozes. Útil se você já tem vozes prontas nele.")
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
                    Text("A próxima janela mostra o resumo, pergunta onde gravar e permite gerar tudo do zero.")
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
                    : "A dublagem fala o texto traduzido. Crie a tradução em Legendar primeiro.")
            }
            .padding(.top, Theme.Spacing.s)
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
        switch app.settings.dubbingEngine {
        case .original: return "Voz original"
        case .voiceStudio: return "Voz clonada (VoiceStudio)"
        case .system: return "Voz \(voice)"
        }
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

    private func checkStudio(force: Bool = false) async {
        guard force || usesClones else { return }
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
