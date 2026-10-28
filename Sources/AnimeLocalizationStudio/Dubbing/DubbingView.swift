import DubbingKit
import MediaKit
import StudioCore
import SwiftUI

/// Dublar: which engine, what will be dubbed and one button, the dubs already made and,
/// for the Mac's voice, its settings (collapsed). Everything shown comes from the model, so
/// clearing or deleting updates the page.
struct DubbingView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @State private var recordToDelete: DubRecord?
    @State private var confirmRestart = false
    @AppStorage("dubVoicesExpanded") private var voicesExpanded = false
    /// Set once the person picks an engine; until then, without an ElevenLabs key, the page opens
    /// on the Mac's voice instead of a page that cannot dub.
    @AppStorage("dubEngineChosen") private var engineChosen = false

    private var segments: [DubSegment] { workspace.dubSegments }
    private var online: Bool { app.settings.dubbingEngine == .elevenLabs }
    private var language: String { Languages.name(for: online ? app.settings.targetLanguage : workspace.dubLanguage) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Text("Dublar").font(.largeTitle.weight(.semibold))
                if let operation = workspace.operation {
                    OperationProgress(message: operation.message, fraction: operation.fraction) { workspace.cancelOperation() }
                }
                if let notice = workspace.notice {
                    HStack {
                        InlineMessage(kind: notice.kind, text: notice.text)
                        if let action = workspace.noticeAction { Button(action.title, action: action.run).buttonStyle(.link) }
                    }
                }
                engines
                summary
                if let dub = workspace.lastDub, !online { DubResultPanel(workspace: workspace, dub: dub) }
                history
                if !online {
                    DisclosureGroup(isExpanded: $voicesExpanded) {
                        DubVoicesSection(workspace: workspace).padding(.top, Theme.Spacing.m)
                    } label: {
                        Label("Ajustar vozes e personagens", systemImage: "person.2.wave.2").font(.headline)
                            .hint("Ajustar vozes e personagens", "Emoção por fala, modo de mixagem e os personagens. O app escolhe tudo sozinho; abra só se quiser mudar.")
                    }
                    restart
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .task {
            if !engineChosen && online && app.elevenLabsKey == nil { app.settings.dubbingEngine = .original }
            workspace.refreshDubStorage()
            await workspace.loadDubText()
            rebuildCast()
        }
        .onChange(of: workspace.dubText?.key) { rebuildCast() }
        .onChange(of: workspace.editor.revision) { rebuildCast() }
        .modifier(SpeakerModelConsent(workspace: workspace))
        .confirmationDialog("Recomeçar a dublagem do zero?", isPresented: $confirmRestart) {
            Button("Recomeçar do zero", role: .destructive) { workspace.clearDubFiles() }
        } message: {
            Text("Apaga as falas geradas, as vozes de cada personagem e a música de fundo deste vídeo (\(bytes)). A próxima dublagem refaz tudo. Os vídeos já dublados e o histórico não são apagados.")
        }
        .confirmationDialog("Apagar esta dublagem?", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
                            presenting: recordToDelete) { record in
            Button(workspace.canTrashOutput(of: record) ? "Apagar o vídeo dublado e recomeçar do zero" : "Tirar do histórico e recomeçar do zero",
                   role: .destructive) {
                workspace.deleteDubRecord(record, trashFile: true, resetVoices: true)
            }
            Button("Só tirar do histórico") { workspace.deleteDubRecord(record, trashFile: false, resetVoices: false) }
        } message: { record in
            Text(deleteMessage(record))
        }
        .sheet(isPresented: Binding(get: { workspace.dubSession != nil }, set: { if !$0 && !isDubRunning { workspace.dubSession = nil } })) {
            DubSessionSheet(workspace: workspace, cast: $workspace.cast, segmentCount: segments.count)
        }
    }

    private var isDubRunning: Bool { if case .running = workspace.dubSession?.phase { true } else { false } }
    private var bytes: String { ByteCountFormatter.string(fromByteCount: workspace.dubStorageBytes, countStyle: .file) }

    // MARK: Engine

    private var engines: some View {
        @Bindable var app = app
        return HStack(alignment: .top, spacing: Theme.Spacing.m) {
            OptionCard(title: "ElevenLabs", systemImage: "cloud",
                       detail: "Recomendado. Ouve o áudio, separa cada personagem, traduz e dubla com a voz de cada um, mantendo a emoção. Online, pago por minuto.",
                       selected: online) { app.settings.dubbingEngine = .elevenLabs; engineChosen = true }
                .hint("ElevenLabs", "Serviço online de dublagem automática: só o áudio do vídeo é enviado (nunca o vídeo). Não precisa de legenda. Usa a sua conta e os seus créditos da ElevenLabs.")
            OptionCard(title: "Voz original no Mac", systemImage: "desktopcomputer",
                       detail: "Gratuita e offline. Lê uma legenda (do vídeo ou traduzida no app) com um clone da voz de cada personagem.",
                       selected: !online) { app.settings.dubbingEngine = .original; engineChosen = true }
                .hint("Voz original no Mac", "Tudo no próprio Mac (Chatterbox Multilingual da Resemble AI, MIT), pela GPU do Apple silicon. Fala 23 idiomas, inclusive português e japonês. Precisa de uma legenda traduzida.")
        }
    }

    // MARK: What will be dubbed

    private var summary: some View {
        Panel {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.l, verticalSpacing: Theme.Spacing.m) {
                GridRow {
                    rowTitle(online ? "Áudio enviado" : "Voz e fundo", "waveform")
                    audioPicker
                }
                if online { onlineRows } else { localRows }
            }
            Divider().padding(.vertical, Theme.Spacing.xs)
            HStack {
                if let warning { Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warning) }
                Spacer()
                Button { workspace.startDubSession() } label: { Label("Dublar…", systemImage: "waveform") }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!workspace.canStartDub || workspace.isBusy || warning != nil)
                    .hintVerbatim("Dublar…", "Mostra o resumo, pergunta onde gravar e então dubla o vídeo inteiro, mostrando cada etapa.")
            }
        }
    }

    private var warning: String? {
        if workspace.audioTracks.isEmpty { return "O vídeo não tem áudio." }
        if online { return app.elevenLabsKey == nil ? "Cole a sua chave da ElevenLabs acima." : nil }
        if workspace.dubText == nil { return "Escolha o texto falado ou crie uma tradução em Legendar." }
        if !ClonedVoiceSynthesizer.supports(workspace.dubLanguage) { return "A voz do Mac ainda não fala \(language). Use a ElevenLabs." }
        return segments.isEmpty ? "A legenda escolhida não tem falas para dublar." : nil
    }

    @ViewBuilder
    private var audioPicker: some View {
        if workspace.audioTracks.count > 1 {
            Picker("Áudio", selection: Binding(get: { workspace.dubAudioTrack?.id ?? -1 }, set: { workspace.selectDubAudio($0) })) {
                ForEach(workspace.audioTracks) { Text(WorkspaceModel.describe($0)).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(workspace.isBusy)
            .hint("Áudio de base", "A faixa com as vozes originais. Use o áudio no idioma original (geralmente o japonês).")
        } else {
            Text(workspace.dubAudioTrack.map(WorkspaceModel.describe) ?? "O vídeo não tem áudio")
        }
    }

    @ViewBuilder
    private var onlineRows: some View {
        @Bindable var app = app
        GridRow {
            rowTitle("Idioma falado", "person.wave.2")
            Picker("Idioma falado", selection: $app.settings.dubbingSourceLanguage) {
                Text("Detectar automaticamente").tag(String?.none)
                ForEach(TranscriptionLanguage.all, id: \.code) { Text($0.name).tag(Optional($0.code)) }
            }
            .labelsHidden().fixedSize()
            .hint("Idioma falado", "O idioma em que os personagens falam. Deixe em automático se não souber.")
        }
        GridRow {
            rowTitle("Dublar para", "globe")
            HStack {
                Picker("Dublar para", selection: $app.settings.targetLanguage) {
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().fixedSize()
                Text("nova faixa de áudio, padrão ao abrir").foregroundStyle(.secondary)
            }
            .hint("Dublar para", "A faixa dublada entra no vídeo; o áudio original e as legendas continuam lá. Antes de gravar, o app pergunta: novo arquivo ou este arquivo.")
        }
        GridRow {
            rowTitle("Conta", "person.crop.circle")
            ElevenLabsAccountView()
        }
        if let pending = workspace.project.remoteDub {
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                InlineMessage(kind: .info, text: "Há uma dublagem para \(Languages.name(for: pending.language)) enviada em \(pending.startedAt.formatted(date: .abbreviated, time: .shortened)). “Dublar…” retoma esse trabalho, sem enviar nem cobrar de novo.")
            }
        }
        GridRow {
            Text("").gridCellUnsizedAxes(.horizontal)
            Text("Só o áudio é enviado, nunca o vídeo. A voz de cada personagem é clonada: use apenas em conteúdo que você tem direito de dublar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var localRows: some View {
        GridRow {
            rowTitle("Texto falado", "text.bubble")
            if workspace.hasTranslationDraft || !workspace.dubTextTracks.isEmpty {
                HStack {
                    Picker("Texto falado", selection: Binding(get: { workspace.dubTextChoice }, set: { if let value = $0 { workspace.chooseDubText(value) } })) {
                        if workspace.hasTranslationDraft {
                            Text("Tradução feita no app · \(Languages.name(for: app.settings.targetLanguage))").tag(Optional(WorkspaceModel.DubTextChoice.translation))
                        }
                        ForEach(workspace.dubTextTracks) { track in
                            Text(Self.trackLabel(track))
                                .tag(Optional(WorkspaceModel.DubTextChoice.track(track.id)))
                        }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(workspace.isBusy)
                    if !segments.isEmpty { Text(Plural.count(segments.count, "fala", "falas")).foregroundStyle(.secondary) }
                }
                .hint("Texto falado", "A legenda que a voz lê, no tempo de cada fala: uma legenda que o vídeo já tem (por exemplo a em português) ou a tradução feita no app. A dublagem sai no idioma dessa legenda.")
            } else {
                HStack {
                    Text("O vídeo não tem legenda de texto.").foregroundStyle(.secondary)
                    Button("Criar em Legendar") { app.show(.subtitles) }.buttonStyle(.link)
                }
            }
        }
        GridRow {
            rowTitle("Vozes", "person.wave.2")
            HStack {
                Text("A própria voz de cada personagem\(app.settings.dubbingPerLineVoice ? ", com a emoção de cada fala" : "") · \(app.settings.dubbingMode.label)")
                Button(voicesExpanded ? "Fechar ajustes" : "Ajustar") { withAnimation { voicesExpanded.toggle() } }.buttonStyle(.link)
            }
        }
        GridRow {
            rowTitle("Resultado", "square.and.arrow.down")
            Text("Nova faixa de áudio em \(language)")
        }
    }

    /// “Legenda do vídeo: Dialogue@Ryuumaru · Inglês”, without repeating a name that is the language.
    static func trackLabel(_ track: MediaTrack) -> String {
        let language = Languages.name(for: EpisodeWorkflow.language(of: track))
        guard let name = track.name, !name.isEmpty, name.caseInsensitiveCompare(language) != .orderedSame else { return "Legenda do vídeo em \(language)" }
        return "Legenda do vídeo: \(name) · \(language)"
    }

    private func rowTitle(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).foregroundStyle(.secondary).frame(minWidth: 130, alignment: .leading)
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Dublagens feitas", systemImage: "clock.arrow.circlepath")
            if workspace.dubHistory.isEmpty {
                Text("Nenhuma ainda. Cada dublagem terminada aparece aqui.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(workspace.dubHistory.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        historyRow(record)
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
            }
        }
    }

    private func historyRow(_ record: DubRecord) -> some View {
        let exists = FileManager.default.fileExists(atPath: record.outputPath)
        let ok = record.verified && record.failedLines == 0
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.translated : Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(record.outputURL.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if record.replacedOriginal { Tag(text: "Este arquivo") }
                    if !exists { Tag(text: "Não encontrado", tint: Theme.warning) }
                }
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.engine) · \(Languages.name(for: record.language))\(record.lines > 0 ? " · " + Plural.count(record.lines, "fala", "falas") : "")\(record.failedLines > 0 ? ", \(record.failedLines) sem voz" : "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .hintVerbatim(record.outputURL.lastPathComponent, "\(record.mode) · áudio \(record.baseAudio) · \(Languages.name(for: record.language))\(ok ? " · verificada" : " · com avisos")\n\(record.outputPath)")
            Spacer(minLength: Theme.Spacing.s)
            if exists {
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([record.outputURL]) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .hint("Mostrar no Finder", "Abre a pasta do vídeo dublado com ele selecionado.")
            }
            Button("Apagar…", systemImage: "trash") { recordToDelete = record }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(workspace.isBusy)
                .hint("Apagar esta dublagem", "Pergunta antes: apagar e recomeçar as vozes do zero, ou só tirar do histórico.")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func deleteMessage(_ record: DubRecord) -> String {
        let reset = "Recomeçar do zero também apaga as vozes de cada personagem e os arquivos guardados desta dublagem (\(bytes)); a próxima dublagem refaz tudo."
        if workspace.canTrashOutput(of: record) { return "“\(record.outputURL.lastPathComponent)” vai para a Lixeira. \(reset)" }
        if record.replacedOriginal { return "Esta dublagem foi gravada neste arquivo, que não é apagado. \(reset)" }
        return "O arquivo não está mais no disco. \(reset)"
    }


    // MARK: Restart

    private var restart: some View {
        HStack {
            Text(workspace.dubStorageBytes > 0 ? "Arquivos guardados para a próxima dublagem: \(bytes)" : "Nenhum arquivo guardado.")
                .font(.caption).foregroundStyle(.secondary)
                .hint("Arquivos guardados", "Falas geradas, vozes separadas e música de fundo. Deixam a próxima dublagem mais rápida: só o que mudou é refeito.")
            Spacer()
            Button("Recomeçar do zero…", systemImage: "arrow.counterclockwise") { confirmRestart = true }
                .controlSize(.small)
                .disabled(workspace.isBusy || (workspace.dubStorageBytes == 0 && workspace.cast.members.allSatisfy { $0.voiceID == nil }))
                .hint("Recomeçar do zero", "Pergunta antes. Apaga as vozes escolhidas e os arquivos guardados, para a próxima dublagem refazer tudo.")
        }
    }


    // MARK: Actions

    private func rebuildCast() {
        var cast = workspace.cast
        cast.addMissing(from: DubbingPlan.speakers(in: segments).filter { $0 != "Desconhecido" })
        workspace.updateCast(cast)
    }
}

/// Right after a dub: what came out and which lines need a look.
private struct DubResultPanel: View {
    @Bindable var workspace: WorkspaceModel
    let dub: (url: URL, report: DubbingReport, verification: VerificationReport)

    var body: some View {
        Panel {
            HStack {
                SectionLabel("Última dublagem", systemImage: "checkmark.seal")
                Spacer()
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([dub.url]) }
                    .buttonStyle(.link)
            }
            let r = dub.report
            Text("\(Plural.count(r.synthesized + r.reusedClips, "fala dublada", "falas dubladas")) · \(r.spedUp.count) aceleradas · \(r.failed.count) sem voz")
                .font(.callout)
            let segments = workspace.dubSegments
            ForEach(r.problemLines.sorted().prefix(8), id: \.self) { id in
                Button("Fala \(id + 1): \(segments.first { $0.id == id }?.text ?? "")") {
                    workspace.select(id, seek: true)
                    workspace.app.show(.subtitles)
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .hint("Revisar a fala", "Abre esta fala em Legendar. Corrigir o texto e dublar de novo refaz só as falas alteradas.")
            }
            if !dub.verification.passed { VerificationList(report: dub.verification) }
        }
    }
}
