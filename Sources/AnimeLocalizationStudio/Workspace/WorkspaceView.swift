import SwiftUI

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case subtitles, dubbing
    var id: String { rawValue }
    var label: String { self == .subtitles ? "Legendas" : "Dublagem" }
    var systemImage: String { self == .subtitles ? "captions.bubble" : "waveform.and.person.filled" }
}

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var mode: WorkspaceMode = ProcessInfo.processInfo.environment["ALS_MODE"] == "dubbing" ? .dubbing : .subtitles
    @State private var confirmRetranslate = false
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
        .navigationTitle(workspace.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .confirmationDialog("Este episódio já tem tradução", isPresented: $confirmRetranslate) {
            Button("Traduzir só as falas que faltam") { workspace.translateEpisode(undoManager: undoManager) }
            Button("Traduzir tudo de novo", role: .destructive) { workspace.translateEpisode(undoManager: undoManager, retranslateAll: true) }
        } message: {
            Text("Falas já traduzidas ou editadas à mão são mantidas, a menos que você escolha traduzir tudo de novo. Nesse caso, uma cópia da tradução atual fica salva no projeto e ⌘Z desfaz a troca.")
        }
    }

    private var subtitle: String {
        guard let info = workspace.info else { return "" }
        var parts = [info.container]
        if let ms = info.durationMilliseconds { parts.append(Duration.milliseconds(ms).formatted(.time(pattern: .hourMinuteSecond))) }
        parts.append(ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private var subtitles: some View {
        VSplitView {
            HStack(alignment: .top, spacing: 0) {
                PlayerView(workspace: workspace)
                    .padding(Theme.Spacing.l)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView(workspace: workspace, requestTranslate: requestTranslate)
                    .frame(width: 340)
            }
            .frame(minHeight: 320, idealHeight: 470)
            EditorPane(workspace: workspace)
                .frame(minHeight: 240, idealHeight: 360)
        }
        .paneBackground()
    }

    private func requestTranslate() {
        if workspace.editor.translatedCount > 0 { confirmRetranslate = true } else { workspace.translateEpisode(undoManager: undoManager) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Modo", selection: $mode) {
                ForEach(WorkspaceMode.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Abrir legenda externa…", systemImage: "doc.badge.plus") { workspace.openExternalSubtitle() }
                .help("Usar uma legenda ASS, SSA ou SRT de fora do vídeo")
            Button("Exportar legenda…", systemImage: "square.and.arrow.up") { workspace.exportTranslation() }
                .disabled(workspace.editor.translation == nil)
                .help("Salvar a tradução como arquivo separado")
            Button("Incorporar ao MKV", systemImage: "film.stack") { workspace.embedTranslation() }
                .disabled(workspace.editor.translation == nil || workspace.isBusy)
                .help("Criar um novo MKV com a faixa em português, sem alterar o original")
            Button("Traduzir episódio inteiro", systemImage: "translate") { requestTranslate() }
                .buttonStyle(.glassProminent)
                .disabled(!workspace.editor.hasDocument || workspace.isBusy)
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .help("Traduz todas as falas preservando estilos e tags (⇧⌘T)")
        }
    }
}
