import MediaKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    let screen: EpisodeScreen
    @Environment(AppModel.self) private var app
    /// The line panel pinned to the whole right side, next to the video and the list.
    @AppStorage("linePanelDocked") private var docked = false
    @AppStorage("lineDetailWidth") private var detailWidth: Double = 0

    var body: some View {
        Group {
            if let error = workspace.loadError {
                EmptyStateView(title: "Não foi possível abrir o arquivo", message: LocalizedStringKey(error), systemImage: "exclamationmark.triangle") {
                    Button("Tentar de novo") { workspace.loadError = nil; Task { await workspace.load() } }
                }
            } else {
                switch screen {
                case .overview: OverviewView(workspace: workspace)
                case .subtitles: subtitles
                case .dubbing: DubbingView(workspace: workspace)
                }
            }
        }
        .navigationTitle(workspace.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .confirmationDialog("Há alterações não salvas", isPresented: Binding(get: { workspace.pendingLeave != nil },
                                                                             set: { if !$0 { workspace.pendingLeave = nil } })) {
            Button("Gravar no vídeo…") { workspace.resolveLeave(.writeToVideo) }
            Button("Exportar arquivo…") { workspace.resolveLeave(.export) }
            Button("Descartar alterações", role: .destructive) { workspace.resolveLeave(.discard) }
            Button("Continuar editando", role: .cancel) { workspace.pendingLeave = nil }
        } message: {
            Text("Esta legenda tem alterações que ainda não estão no vídeo nem num arquivo.\nGravar no vídeo ou Exportar: salva antes de continuar.\nDescartar: a legenda volta a ser a que está no vídeo.")
        }
        .confirmationDialog("Baixar o modelo de fala?", isPresented: Binding(get: { workspace.pendingModelDownload != nil },
                                                                              set: { if !$0 { workspace.pendingModelDownload = nil } })) {
            Button("Baixar e transcrever") {
                workspace.pendingModelDownload = nil
                workspace.transcriptionRetry?()
                workspace.transcriptionRetry = nil
            }
        } message: {
            Text("O macOS precisa baixar o modelo de reconhecimento de fala para este idioma. O download é feito e gerenciado pelo sistema (modelo da Apple, uso no dispositivo) e fica disponível para outros apps.")
        }
        .alert("Usar os tempos de “\(workspace.pendingTimingOffer.map { $0.name ?? $0.codec } ?? "")” nesta legenda?",
               isPresented: Binding(get: { workspace.pendingTimingOffer != nil }, set: { if !$0 && workspace.pendingTimingOffer != nil { workspace.declineReferenceTiming() } })) {
            Button("Sim, usar os tempos") { workspace.useReferenceTiming() }.keyboardShortcut(.defaultAction)
            Button("Não", role: .cancel) { workspace.declineReferenceTiming() }
        } message: {
            Text("A legenda que você edita está vazia e a do lado tem outros tempos.\nSim: ela ganha as mesmas falas, nos mesmos tempos, estilos e posições, em branco para você escrever ao lado.\nNão: “Ao lado” volta para Nenhuma.")
        }
        .sheet(isPresented: $workspace.showWriteSheet) { WriteToVideoSheet(workspace: workspace) }
        .sheet(item: $workspace.translateSheet) { start in TranslateSheet(workspace: workspace, start: start) }
        .sheet(isPresented: $workspace.showNewSubtitleSheet) { NewSubtitleSheet(workspace: workspace) }
        .confirmationDialog("Onde gravar as faixas padrão?", isPresented: $workspace.askDefaultsDestination) {
            Button("Alterar este arquivo") { workspace.applyDefaults(inPlace: true) }
            Button("Criar uma cópia") { workspace.applyDefaults(inPlace: false) }
        } message: {
            Text("Neste arquivo a mudança é instantânea: só o cabeçalho do MKV muda, o vídeo e o áudio não são tocados. A cópia duplica o arquivo inteiro.")
        }
    }

    private var subtitle: String {
        guard let info = workspace.info else { return "" }
        var parts = [info.container]
        if let ms = info.durationMilliseconds { parts.append(Duration.milliseconds(ms).formatted(.time(pattern: .hourMinuteSecond))) }
        parts.append(ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    /// Legendar: the bar with what is edited and how to save it, then the video and the lines.
    private var subtitles: some View {
        VStack(spacing: 0) {
            SubtitleSessionBar(workspace: workspace)
            if workspace.operation != nil || workspace.notice != nil {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if let operation = workspace.operation {
                        OperationProgress(message: operation.message, fraction: operation.fraction,
                                          onCancel: operation.kind == .loading ? nil : { workspace.cancelOperation() })
                    }
                    if let notice = workspace.notice {
                        HStack {
                            InlineMessage(kind: notice.kind, text: notice.text)
                            if let action = workspace.noticeAction { Button(action.title, action: action.run).buttonStyle(.link) }
                            Spacer()
                            Button("Fechar aviso", systemImage: "xmark") { workspace.notice = nil }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .hint("Fechar aviso", "Esconde esta mensagem.")
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.s)
            }
            Divider()
            if docked {
                GeometryReader { proxy in
                    let range = LinePanelWidth.range(for: proxy.size.width)
                    let panel = LinePanelWidth.clamp(detailWidth, to: range)
                    HStack(spacing: 0) {
                        videoAndLines.frame(maxWidth: .infinity)
                        PanelEdge(width: $detailWidth, current: panel, range: range)
                        LineDetailView(workspace: workspace).frame(width: panel)
                    }
                }
                .transition(.opacity)
            } else {
                videoAndLines
            }
        }
        .animation(.smooth(duration: 0.25), value: docked)
        .paneBackground()
    }

    private var videoAndLines: some View {
        VSplitView {
            PlayerView(workspace: workspace)
                .padding(Theme.Spacing.l)
                .frame(minHeight: 200, idealHeight: 420, maxHeight: .infinity)
            EditorPane(workspace: workspace)
                .frame(minHeight: 200, idealHeight: 360)
        }
    }

    /// The only thing at the top of the window: the three pages of the video.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ScreenTabs(selected: app.screen, isEnabled: !workspace.isBusy) { app.show($0) }
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// Top of Legendar: what is edited and what is beside it on the left, Traduzir in the middle,
/// Novo and Salvar on the right. One subtitle is edited at a time.
private struct SubtitleSessionBar: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            tracks.frame(maxWidth: .infinity, alignment: .leading)
            Button { workspace.translateSheet = TranslateSheetStart() } label: {
                Label("Traduzir", systemImage: "translate").padding(.horizontal, Theme.Spacing.s)
            }
            .buttonStyle(.glass)
            .disabled(workspace.isBusy || (workspace.audioTracks.isEmpty && textTracks.isEmpty && !editor.hasDocument))
            .hint("Traduzir (⇧⌘T)", "Cria uma legenda em outro idioma, a partir de uma legenda do vídeo ou do áudio. Ela passa a ser a editada, com a de origem ao lado.")
            HStack(spacing: Theme.Spacing.s) {
                newMenu
                saveMenu
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    private var editor: EditorModel { workspace.editor }
    private var textTracks: [MediaTrack] { workspace.subtitleTracks.filter { $0.textSubtitleExtension != nil } }

    /// -3 the translation being edited, -2 a subtitle that did not come from the video.
    private var mainID: Int {
        if !workspace.isEditingOriginal { return -3 }
        return workspace.project.externalSubtitlePath != nil ? -2 : (workspace.project.sourceTrackID ?? -1)
    }

    private var openSubtitleName: String {
        workspace.project.newTrackName ?? workspace.project.newTrackLanguage.map(Languages.name(for:)) ?? "Legenda nova"
    }

    private var tracks: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("Editando").foregroundStyle(.secondary)
            Picker("Editando", selection: Binding(get: { mainID }, set: { workspace.requestTracks(main: $0, reference: workspace.project.referenceTrackID) })) {
                if !workspace.isEditingOriginal {
                    Text("Tradução · \(Languages.name(for: workspace.app.settings.targetLanguage))").tag(-3)
                }
                if workspace.project.externalSubtitlePath != nil { Text("\(openSubtitleName) · nova").tag(-2) }
                ForEach(textTracks) { Text(label($0)).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .hint("Legenda que você edita", "Uma legenda por vez. Sem alterações, troca na hora; com alterações não salvas, o app pergunta antes (salvar, descartar ou continuar).")
            if workspace.isEditingOriginal && workspace.project.referenceTrackID != nil && workspace.project.externalSubtitlePath == nil {
                Button("Inverter", systemImage: "arrow.left.arrow.right") { workspace.swapEditedAndReference() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hint("Inverter (⇄)", "A legenda ao lado passa a ser a editada, e a editada vai para o lado.")
            }
            Text("Ao lado").foregroundStyle(.secondary)
            beside
        }
        .disabled(workspace.isBusy)
    }

    /// The subtitle beside (read only). While translating it is the subtitle the translation
    /// comes from; while correcting, any other subtitle of the video, or none.
    @ViewBuilder
    private var beside: some View {
        if workspace.isEditingOriginal {
            let others = textTracks.filter { $0.id != mainID }
            Picker("Ao lado", selection: Binding(get: { workspace.project.referenceTrackID ?? -1 },
                                                 set: { workspace.requestTracks(main: mainID, reference: $0 < 0 ? nil : $0) })) {
                Text("Nenhuma").tag(-1)
                ForEach(others) { Text(label($0)).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(others.isEmpty)
            .hint("Legenda ao lado", others.isEmpty
                  ? "O vídeo não tem outra legenda de texto para mostrar ao lado."
                  : "Outra legenda do vídeo exibida ao lado de cada fala, só para consulta. As falas são casadas pelo tempo.")
        } else {
            Picker("Ao lado", selection: .constant(0)) { Text(editor.referenceTitle ?? "Original").tag(0) }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(true)
                .hint("Legenda ao lado", "A legenda de onde a tradução veio, ao lado de cada fala para consulta.")
        }
    }

    private func label(_ track: MediaTrack) -> String { "\(track.name ?? track.codec) · \(Languages.display(track.displayLanguage))" }

    private var newMenu: some View {
        Menu {
            Button("Legenda…") { workspace.showNewSubtitleSheet = true }
            Button("Importar arquivo…") { workspace.requestNewSubtitle(.importFile) }
        } label: {
            Label("Novo", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(workspace.isBusy)
        .hint("Novo", "Legenda… começa uma em branco, com o nome e o idioma que você escolher. Importar arquivo… abre um ASS, SSA ou SRT do disco. Com alterações não salvas, o app pergunta antes.")
    }

    private var saveMenu: some View {
        Menu {
            Button("Gravar no vídeo…") { workspace.requestWriteToVideo() }
            Button("Exportar arquivo…") { workspace.exportCurrent() }
        } label: {
            Label("Salvar", systemImage: "square.and.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.glassProminent)
        .fixedSize()
        .disabled(!canSave || workspace.isBusy)
        .hint("Salvar", "Gravar no vídeo (⌘S): a legenda entra no MKV, e o app pergunta antes se é um novo arquivo ou este. Exportar arquivo (⇧⌘E): salva como ASS/SRT separado, sem mexer no vídeo.")
    }

    private var canSave: Bool { editor.hasDocument && (workspace.isEditingOriginal || editor.translation != nil) }
}
