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
            Button("Manter como rascunho") { workspace.resolveLeave(.keepDraft) }
            Button("Descartar alterações", role: .destructive) { workspace.resolveLeave(.discard) }
            Button("Continuar editando", role: .cancel) { workspace.pendingLeave = nil }
        } message: {
            Text("Gravar no vídeo: grava agora (você escolhe novo arquivo ou este arquivo).\nRascunho: as alterações ficam guardadas no app para continuar depois; o vídeo não muda.\nDescartar: volta a legenda para como estava quando a tela abriu.")
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
            Divider()
            HStack(spacing: 0) {
                editorArea.frame(maxWidth: .infinity)
                Divider()
                InspectorView(workspace: workspace, requestTranslate: requestTranslate)
                    .frame(width: Self.inspectorWidth)
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
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
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

    private var title: String {
        workspace.isEditingOriginal ? "Corrigindo uma legenda" : "Legenda nova em \(Languages.name(for: workspace.app.settings.targetLanguage))"
    }

    private var subtitle: String {
        let base = workspace.project.externalSubtitlePath != nil ? "arquivo do disco"
            : workspace.subtitleTracks.first { $0.id == workspace.project.sourceTrackID }.map { "\($0.name ?? $0.codec) · \(Languages.display($0.displayLanguage))" } ?? "—"
        if workspace.isEditingOriginal {
            return workspace.editor.referenceTitle.map { "\(base) · ao lado: \($0)" } ?? base
        }
        return "a partir de \(base)"
    }
}
