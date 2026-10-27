import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case subtitles, dubbing
    var id: String { rawValue }
    var label: String { self == .subtitles ? "Legendas" : "Dublagem" }
    var systemImage: String { self == .subtitles ? "captions.bubble" : "waveform.and.person.filled" }
}

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    let mode: WorkspaceMode
    @State private var confirmRetranslate = false
    @AppStorage("inspectorShown") private var showInspector = true
    @AppStorage("inspectorChosen") private var inspectorChosen = false
    @State private var isDocked = true
    @State private var drawerOpen = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let error = workspace.loadError {
                EmptyStateView(title: "Não foi possível abrir o arquivo", message: LocalizedStringKey(error), systemImage: "exclamationmark.triangle") {
                    Button("Tentar de novo") { workspace.loadError = nil; Task { await workspace.load() } }
                }
            } else if mode == .subtitles {
                subtitles
            } else {
                DubbingView(workspace: workspace)
            }
        }
        .navigationTitle(mode == .dubbing ? "Dublar · \(workspace.title)" : workspace.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .confirmationDialog("Onde gravar a legenda traduzida?", isPresented: $workspace.askEmbedDestination) {
            Button("Criar um novo arquivo") { workspace.embedTranslation(replaceOriginal: false) }
            Button("Incorporar no próprio arquivo", role: .destructive) { workspace.embedTranslation(replaceOriginal: true) }
        } message: {
            Text("Novo arquivo: cria “\(workspace.title) [\(appTarget)].mkv” ao lado e não mexe no original.\nPróprio arquivo: o MKV é regravado com a nova faixa (o vídeo não é recodificado), conferido, e só então substitui o original, que vai para a Lixeira.")
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

    /// The inspector sits beside the editor when both fit (editor ≥ 600 pt); in narrower windows
    /// it opens as a drawer over the trailing edge instead of squeezing everything.
    private static let inspectorWidth: CGFloat = 320
    private static let editorMinimum: CGFloat = 540

    private var subtitles: some View {
        GeometryReader { proxy in
            let docked = proxy.size.width >= Self.editorMinimum + Self.inspectorWidth
            let _ = updateDocked(docked)
            HStack(spacing: 0) {
                editorArea
                    .frame(maxWidth: .infinity)
                if showInspector && docked {
                    Divider()
                    inspector.frame(width: Self.inspectorWidth)
                }
            }
            .overlay(alignment: .trailing) {
                if drawerOpen && !docked {
                    inspector
                        .frame(width: min(Self.inspectorWidth, proxy.size.width - 40))
                        .background(.regularMaterial)
                        .shadow(color: .black.opacity(0.25), radius: 12, x: -2)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.smooth(duration: 0.2), value: docked)
        }
        .paneBackground()
        .onAppear { if !inspectorChosen { showInspector = true } }
    }

    /// Narrow windows collapse the inspector automatically; the toolbar button opens it as a drawer.
    private func updateDocked(_ docked: Bool) {
        guard docked != isDocked else { return }
        Task { @MainActor in
            isDocked = docked
            drawerOpen = false
        }
    }

    private var editorArea: some View {
        VSplitView {
            PlayerView(workspace: workspace)
                .padding(Theme.Spacing.l)
                .frame(minHeight: 220, idealHeight: 460, maxHeight: .infinity)
            EditorPane(workspace: workspace)
                .frame(minHeight: 220, idealHeight: 360)
        }
    }

    private var inspector: some View {
        InspectorView(workspace: workspace, requestTranslate: requestTranslate)
    }

    private func requestTranslate() {
        if workspace.editor.translatedCount > 0 { confirmRetranslate = true } else { workspace.translateEpisode(undoManager: undoManager) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if mode == .subtitles {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Traduzir episódio inteiro", systemImage: "translate") { requestTranslate() }
                    .buttonStyle(.glassProminent)
                    .disabled(!workspace.editor.hasDocument || workspace.isBusy)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .hint("Traduzir episódio inteiro (⇧⌘T)", "Traduz todas as falas com o motor escolhido, mantendo estilos, tempos e tags. Falas já traduzidas são mantidas.")
                Menu {
                    Button("Abrir legenda externa…", systemImage: "doc.badge.plus") { workspace.openExternalSubtitle() }
                    Button("Exportar legenda…", systemImage: "square.and.arrow.up") { workspace.exportTranslation() }
                        .disabled(workspace.editor.translation == nil)
                    Divider()
                    Button("Incorporar ao MKV…", systemImage: "film.stack") { workspace.requestEmbed() }
                        .disabled(workspace.editor.translation == nil || workspace.isBusy)
                } label: {
                    Label("Arquivo", systemImage: "ellipsis.circle")
                }
                .hint("Arquivo", "Abrir uma legenda externa, exportar a tradução como arquivo ou incorporá-la ao MKV.")
                Button("Inspetor", systemImage: "sidebar.trailing") {
                    if isDocked { showInspector.toggle(); inspectorChosen = true } else { drawerOpen.toggle() }
                }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .hint("Mostrar ou esconder o inspetor (⌥⌘I)", "O painel da direita com as faixas, a tradução e o novo MKV. Em janelas estreitas ele se recolhe sozinho e este botão o abre por cima.")
            }
        }
    }
}
