import MediaKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    let screen: EpisodeScreen
    @State private var confirmRetranslate = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let error = workspace.loadError {
                EmptyStateView(title: "Não foi possível abrir o arquivo", message: LocalizedStringKey(error), systemImage: "exclamationmark.triangle") {
                    Button("Tentar de novo") { workspace.loadError = nil; Task { await workspace.load() } }
                }
            } else {
                switch screen {
                case .overview: OverviewView(workspace: workspace)
                case .subtitles:
                    if workspace.project.subtitleTask == nil { SubtitleStartForm(workspace: workspace) } else { subtitles }
                case .dubbing: DubbingView(workspace: workspace)
                }
            }
        }
        .navigationTitle(workspace.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .confirmationDialog("Você alterou a legenda", isPresented: Binding(get: { workspace.pendingLeave != nil },
                                                                          set: { if !$0 { workspace.pendingLeave = nil } })) {
            Button("Gravar no vídeo…") { workspace.resolveLeave(.writeToVideo) }
            if workspace.pendingLeave?.keepsDraft != false {
                Button("Manter como rascunho") { workspace.resolveLeave(.keepDraft) }
                Button("Descartar alterações", role: .destructive) { workspace.resolveLeave(.discard) }
            } else {
                Button("Descartar e trocar", role: .destructive) { workspace.resolveLeave(.keepDraft) }
            }
            Button("Continuar editando", role: .cancel) { workspace.pendingLeave = nil }
        } message: {
            Text(workspace.pendingLeave?.keepsDraft != false
                 ? "Gravar no vídeo: grava agora (você escolhe novo arquivo ou este arquivo).\nRascunho: as alterações ficam guardadas no app para continuar depois; o vídeo não muda.\nDescartar: volta a legenda para como estava quando a tela abriu."
                 : "Trocar a legenda descarta o rascunho desta (uma cópia da tradução fica no projeto). Grave no vídeo antes se quiser manter as alterações.")
        }
        .confirmationDialog("Onde gravar a legenda nova?", isPresented: $workspace.askEmbedDestination) {
            Button("Criar um novo arquivo") { workspace.embedTranslation(replaceOriginal: false) }
            Button("Gravar neste arquivo", role: .destructive) { workspace.embedTranslation(replaceOriginal: true) }
        } message: {
            Text("Novo arquivo: cria “\(workspace.title) [\(appTarget)].mkv” ao lado e não mexe no original.\nEste arquivo: o MKV é regravado com a nova faixa (o vídeo não é recodificado), conferido, e só então substitui o original, que vai para a Lixeira.")
        }
        .confirmationDialog("Onde gravar a legenda corrigida?", isPresented: $workspace.askSaveEditedDestination) {
            Button("Criar um novo arquivo") { workspace.saveEditedSubtitle(replaceOriginal: false) }
            Button("Gravar neste arquivo", role: .destructive) { workspace.saveEditedSubtitle(replaceOriginal: true) }
        } message: {
            Text("A legenda corrigida entra no lugar da faixa de onde veio, com o mesmo idioma, nome e flags; as outras faixas não mudam e o vídeo não é recodificado.\nNovo arquivo: cria “\(workspace.title) [editado].mkv” ao lado.\nEste arquivo: o MKV é regravado, conferido, e só então substitui o original, que vai para a Lixeira.")
        }
        .sheet(isPresented: $workspace.showSeries) {
            VStack(spacing: 0) {
                SeriesView().frame(minWidth: 760, minHeight: 480)
                Divider()
                HStack { Spacer(); Button("Fechar") { workspace.showSeries = false }.keyboardShortcut(.defaultAction) }
                    .padding(Theme.Spacing.m)
            }
        }
        .confirmationDialog("Onde gravar as faixas padrão?", isPresented: $workspace.askDefaultsDestination) {
            Button("Alterar este arquivo") { workspace.applyDefaults(inPlace: true) }
            Button("Criar uma cópia") { workspace.applyDefaults(inPlace: false) }
        } message: {
            Text("Neste arquivo a mudança é instantânea: só o cabeçalho do MKV muda, o vídeo e o áudio não são tocados. A cópia duplica o arquivo inteiro.")
        }
        .confirmationDialog("Este episódio já tem tradução", isPresented: $confirmRetranslate) {
            Button("Traduzir só as falas que faltam") { workspace.translateEpisode(undoManager: undoManager) }
            Button("Traduzir tudo de novo", role: .destructive) { workspace.translateEpisode(undoManager: undoManager, retranslateAll: true) }
        } message: {
            Text("Falas já traduzidas ou editadas à mão são mantidas, a menos que você escolha traduzir tudo de novo. Nesse caso, uma cópia da tradução atual fica salva no projeto e ⌘Z desfaz a troca.")
        }
    }

    @Environment(AppModel.self) private var app
    private var appTarget: String { app.settings.targetLanguage.uppercased() }

    private var subtitle: String {
        guard let info = workspace.info else { return "" }
        var parts = [info.container]
        if let ms = info.durationMilliseconds { parts.append(Duration.milliseconds(ms).formatted(.time(pattern: .hourMinuteSecond))) }
        parts.append(ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private static let inspectorWidth: CGFloat = 320

    /// Legendar after the task was chosen: a bar to go back or keep/discard changes, the video
    /// and the lines, and the panel with everything the task needs.
    private var subtitles: some View {
        VStack(spacing: 0) {
            SubtitleSessionBar(workspace: workspace)
            if workspace.isEditingOriginal && (workspace.operation != nil || workspace.notice != nil) {
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
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.s)
            }
            Divider()
            HStack(spacing: 0) {
                editorArea.frame(maxWidth: .infinity)
                // Correcting needs nothing beside the editor; a new subtitle has its tools there.
                if !workspace.isEditingOriginal {
                    Divider()
                    InspectorView(workspace: workspace, requestTranslate: requestTranslate)
                        .frame(width: Self.inspectorWidth)
                }
            }
        }
        .paneBackground()
    }

    private var editorArea: some View {
        VSplitView {
            PlayerView(workspace: workspace)
                .padding(Theme.Spacing.l)
                .frame(minHeight: 200, idealHeight: 420, maxHeight: .infinity)
            EditorPane(workspace: workspace)
                .frame(minHeight: 200, idealHeight: 360)
        }
    }

    private func requestTranslate() {
        if workspace.editor.translatedCount > 0 { confirmRetranslate = true } else { workspace.translateEpisode(undoManager: undoManager) }
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

/// Top of Legendar: back to the start form, what is being edited, the draft state and the
/// one way to save into the video.
private struct SubtitleSessionBar: View {
    @Bindable var workspace: WorkspaceModel
    @State private var confirmDiscardDraft = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button { workspace.requestBackToChooser() } label: { Label("Voltar", systemImage: "chevron.left") }
                .disabled(workspace.isBusy)
                .hint("Voltar", "Volta à escolha do que editar e recarrega tudo. Se você alterou algo, o app pergunta se grava, guarda como rascunho ou descarta.")
            Divider().frame(height: 20)
            if workspace.isEditingOriginal { editChips } else { newChips }
            Spacer(minLength: Theme.Spacing.s)
            if workspace.hasDraft {
                Menu {
                    Button("Descartar rascunho…", role: .destructive) { confirmDiscardDraft = true }
                } label: {
                    Label("Rascunho", systemImage: "circle.fill").labelStyle(.titleAndIcon)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.warning)
                .imageScale(.small)
                .fixedSize()
                .hint("Rascunho", "Há alterações guardadas no app que ainda não estão no vídeo. Use “Gravar no vídeo…” para gravá-las, ou descarte o rascunho neste menu.")
            }
            if workspace.isEditingOriginal {
                Menu {
                    Button("Salvar como arquivo de legenda…") { workspace.exportSource() }
                    Button("Editar séries e glossários…") { workspace.showSeries = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .hint("Mais", "Salvar a legenda como arquivo separado (sem mexer no vídeo) e editar séries e glossários.")
            }
            Button { workspace.requestWriteToVideo() } label: { Label("Gravar no vídeo…", systemImage: "square.and.arrow.down.on.square") }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canWrite || workspace.isBusy)
                .hint("Gravar no vídeo (⌘S)", workspace.isEditingOriginal
                      ? "Grava a legenda corrigida no lugar da faixa original. Antes, pergunta: novo arquivo ou este arquivo."
                      : "Grava a legenda nova como faixa do vídeo. Antes, pergunta: novo arquivo ou este arquivo.")
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .confirmationDialog("Descartar o rascunho?", isPresented: $confirmDiscardDraft) {
            Button("Descartar rascunho", role: .destructive) { workspace.discardDraft() }
        } message: {
            Text(workspace.isEditingOriginal
                 ? "Todas as correções que ainda não foram gravadas no vídeo são perdidas e a legenda volta a ser a do vídeo."
                 : "A legenda nova é apagada (uma cópia de segurança fica no projeto).")
        }
    }

    private var canWrite: Bool {
        workspace.editor.hasDocument && (workspace.isEditingOriginal || workspace.editor.translation != nil)
    }

    private var textTracks: [MediaTrack] { workspace.subtitleTracks.filter { $0.textSubtitleExtension != nil } }
    private var mainID: Int { workspace.project.externalSubtitlePath != nil ? -2 : (workspace.project.sourceTrackID ?? -1) }

    /// Correcting: the subtitle edited, ⇄, and the one beside it.
    private var editChips: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("Editando").foregroundStyle(.secondary)
            trackPicker(selection: Binding(get: { mainID }, set: { workspace.requestTracks(main: $0, reference: workspace.project.referenceTrackID) }),
                        none: false)
                .hint("Legenda que você edita", "Trocar de legenda descarta o rascunho da atual; se houver, o app pergunta antes.")
            Button { workspace.swapEditedAndReference() } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.borderless)
                .disabled(workspace.project.referenceTrackID == nil || workspace.isBusy)
                .hint("Inverter (⇄)", "A legenda ao lado passa a ser a editada, e a editada vai para o lado.")
            Text("Ao lado").foregroundStyle(.secondary)
            trackPicker(selection: Binding(get: { workspace.project.referenceTrackID ?? -1 },
                                           set: { workspace.requestTracks(main: mainID, reference: $0 < 0 ? nil : $0) }),
                        none: true)
                .hint("Legenda ao lado", "Outra legenda do vídeo exibida ao lado de cada fala, só para consulta. As falas são casadas pelo tempo.")
        }
        .disabled(workspace.isBusy)
    }

    /// New subtitle: its language and the base it comes from.
    private var newChips: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("Legenda nova em").foregroundStyle(.secondary)
            Picker("Idioma", selection: Binding(get: { workspace.app.settings.targetLanguage }, set: { workspace.changeOutputLanguage($0) })) {
                ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
            }
            .labelsHidden().fixedSize()
            .hint("Idioma da legenda nova", "Cada idioma tem o seu rascunho; trocar não apaga nada.")
            Text("a partir de").foregroundStyle(.secondary)
            trackPicker(selection: Binding(get: { mainID }, set: { workspace.requestTracks(main: $0, reference: nil) }), none: false)
                .hint("Legenda base", "A legenda que é traduzida. Trocar de base recomeça a tradução (uma cópia da atual fica no projeto); o app pergunta antes.")
        }
        .disabled(workspace.isBusy)
    }

    private func trackPicker(selection: Binding<Int>, none: Bool) -> some View {
        Picker("Legenda", selection: selection) {
            if none { Text("Nenhuma").tag(-1) }
            ForEach(textTracks) { track in
                Text("\(track.name ?? track.codec) · \(Languages.display(track.displayLanguage))").tag(track.id)
            }
            if !none && workspace.project.externalSubtitlePath != nil { Text("Arquivo do disco").tag(-2) }
        }
        .labelsHidden()
        .frame(maxWidth: 210)
    }
}
