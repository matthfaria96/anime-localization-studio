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
        if mode == .subtitles {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Abrir legenda externa…", systemImage: "doc.badge.plus") { workspace.openExternalSubtitle() }
                    .hint("Abrir legenda externa", "Usa um arquivo de legenda ASS, SSA ou SRT de fora do vídeo como legenda original.")
                Button("Exportar legenda…", systemImage: "square.and.arrow.up") { workspace.exportTranslation() }
                    .disabled(workspace.editor.translation == nil)
                    .hint("Exportar legenda", "Salva a tradução como um arquivo de legenda separado, ao lado do vídeo.")
                Button("Incorporar ao MKV", systemImage: "film.stack") { workspace.requestEmbed() }
                    .disabled(workspace.editor.translation == nil || workspace.isBusy)
                    .hint("Incorporar ao MKV", "Cria um novo arquivo MKV com a legenda traduzida como faixa extra. O original não é alterado e o vídeo não é recodificado.")
                Button("Traduzir episódio inteiro", systemImage: "translate") { requestTranslate() }
                    .buttonStyle(.glassProminent)
                    .disabled(!workspace.editor.hasDocument || workspace.isBusy)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .hint("Traduzir episódio inteiro (⇧⌘T)", "Traduz todas as falas com o motor escolhido, mantendo estilos, tempos e tags. Falas já traduzidas são mantidas.")
            }
        }
    }
}
