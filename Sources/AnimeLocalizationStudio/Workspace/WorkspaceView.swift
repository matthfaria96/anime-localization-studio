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
                    if workspace.project.subtitleTask == nil { SubtitleTaskChooser(workspace: workspace) } else { subtitles }
                case .dubbing: DubbingView(workspace: workspace)
                }
            }
        }
        .navigationTitle(workspace.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .confirmationDialog("Salvar as alterações da legenda?", isPresented: Binding(get: { workspace.pendingLeave != nil },
                                                                                    set: { if !$0 { workspace.pendingLeave = nil } })) {
            Button("Salvar") { workspace.resolveLeave(save: true) }
            Button("Descartar alterações", role: .destructive) { workspace.resolveLeave(save: false) }
            Button("Continuar editando", role: .cancel) { workspace.pendingLeave = nil }
        } message: {
            Text("Você alterou a legenda nesta tela. Salvar guarda as alterações no projeto; descartar volta a legenda para como estava quando a tela carregou.")
        }
        .confirmationDialog("Onde gravar a legenda traduzida?", isPresented: $workspace.askEmbedDestination) {
            Button("Criar um novo arquivo") { workspace.embedTranslation(replaceOriginal: false) }
            Button("Incorporar no próprio arquivo", role: .destructive) { workspace.embedTranslation(replaceOriginal: true) }
        } message: {
            Text("Novo arquivo: cria “\(workspace.title) [\(appTarget)].mkv” ao lado e não mexe no original.\nPróprio arquivo: o MKV é regravado com a nova faixa (o vídeo não é recodificado), conferido, e só então substitui o original, que vai para a Lixeira.")
        }
        .confirmationDialog("Onde gravar a legenda corrigida?", isPresented: $workspace.askSaveEditedDestination) {
            Button("Criar um novo arquivo") { workspace.saveEditedSubtitle(replaceOriginal: false) }
            Button("Gravar no próprio arquivo", role: .destructive) { workspace.saveEditedSubtitle(replaceOriginal: true) }
        } message: {
            Text("A legenda corrigida entra no lugar da faixa de onde veio, com o mesmo idioma, nome e flags; as outras faixas não mudam e o vídeo não é recodificado.\nNovo arquivo: cria “\(workspace.title) [editado].mkv” ao lado.\nPróprio arquivo: o MKV é regravado, conferido, e só então substitui o original, que vai para a Lixeira.")
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
            Button("Alterar o próprio arquivo") { workspace.applyDefaults(inPlace: true) }
            Button("Criar uma cópia") { workspace.applyDefaults(inPlace: false) }
        } message: {
            Text("No próprio arquivo a mudança é instantânea: só o cabeçalho do MKV muda, o vídeo e o áudio não são tocados. A cópia duplica o arquivo inteiro.")
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
            Picker("Página", selection: Binding(get: { app.screen }, set: { app.show($0) })) {
                ForEach(EpisodeScreen.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .disabled(workspace.isBusy)
            .hint("Páginas do vídeo", "Visão geral: dados e faixas do arquivo. Legendar: corrigir ou traduzir uma legenda. Dublar: criar o áudio dublado. Cada página carrega os dados do vídeo de novo.")
        }
    }
}

/// Top of Legendar: back to the choice of task, what is being done, and keep/discard changes.
private struct SubtitleSessionBar: View {
    @Bindable var workspace: WorkspaceModel
    @State private var confirmDiscard = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button { workspace.requestBackToChooser() } label: { Label("Voltar", systemImage: "chevron.left") }
                .disabled(workspace.isBusy)
                .hint("Voltar", "Volta à escolha entre editar uma legenda existente e criar uma tradução, e recarrega tudo. Se houver alterações, o app pergunta se quer salvá-las ou descartá-las.")
            Label(workspace.isEditingOriginal ? "Editando uma legenda existente" : "Criando uma tradução",
                  systemImage: workspace.isEditingOriginal ? "pencil.line" : "translate")
                .font(.headline)
            Spacer(minLength: Theme.Spacing.s)
            if workspace.showsUnsavedChanges {
                Label("Alterações não salvas", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                Button("Descartar") { confirmDiscard = true }
                    .disabled(workspace.isBusy)
                    .hint("Descartar alterações", "Volta a legenda para como estava quando esta tela carregou.")
                Button("Salvar") { workspace.saveSubtitleSession() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(workspace.isBusy)
                    .hint("Salvar alterações (⌘S)", "Guarda as alterações no projeto. O vídeo só muda quando você usar “Salvar no MKV…” ou “Incorporar ao MKV…”, no painel da direita.")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .confirmationDialog("Descartar as alterações?", isPresented: $confirmDiscard) {
            Button("Descartar alterações", role: .destructive) { workspace.discardSubtitleChanges() }
        } message: {
            Text("A legenda volta a ser como estava quando esta tela carregou.")
        }
    }
}
