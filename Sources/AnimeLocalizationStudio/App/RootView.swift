import StudioCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { app.selection }, set: select)) {
                if let workspace = app.workspace {
                    Section {
                        Label("Visão geral", systemImage: "film").tag(SidebarItem.overview)
                            .hint("Visão geral", "O arquivo aberto: tamanho, codecs, faixas de áudio e legenda, faixas padrão e extração. Daqui você vai para Legendar ou Dublar.")
                        Label("Legendar", systemImage: "captions.bubble").tag(SidebarItem.subtitles)
                            .hint("Legendar", "Corrija uma legenda do arquivo ou crie uma tradução a partir dela.")
                        Label("Dublar", systemImage: "waveform.and.person.filled").tag(SidebarItem.dubbing)
                            .hint("Dublar", "Crie uma faixa de áudio dublada a partir da legenda traduzida, com as vozes dos personagens.")
                    } header: {
                        Text(workspace.title).lineLimit(1)
                    }
                }
                Section("Estúdio") {
                    Label("Abrir episódio…", systemImage: "plus.rectangle.on.folder").tag(SidebarItem.openEpisode)
                        .hint("Abrir episódio (⌘O)", "Escolha um MKV, MP4 ou MOV. As faixas são lidas sem alterar o arquivo.")
                    Label("Biblioteca", systemImage: "square.stack.3d.up").tag(SidebarItem.library)
                        .hint("Biblioteca", "Pastas de temporadas: veja o estado de cada episódio e traduza ou incorpore vários de uma vez.")
                    Label("Fila", systemImage: "list.bullet.clipboard").tag(SidebarItem.queue)
                        .badge(app.queue.pendingCount)
                        .hint("Fila", "Traduções e incorporações em lote, uma de cada vez, em segundo plano.")
                }
                let recents = app.recentProjects.filter { $0.mediaPath != app.workspace?.url.standardizedFileURL.path }.prefix(8)
                if !recents.isEmpty {
                    Section("Recentes") {
                        ForEach(recents) { project in
                            Label {
                                Text(project.title).lineLimit(1)
                            } icon: {
                                StatusDot(color: project.translationStatus == .muxed ? Theme.translated : project.translationStatus == .new ? .secondary.opacity(0.4) : .accentColor)
                            }
                            .tag(SidebarItem.recent(project.id))
                            .hintVerbatim(project.title, project.mediaPath)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .alert(item: Bindable(app).alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .task { await app.refreshTools() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.hasDirectoryPath { app.library.add(url); app.selection = .library } else { app.open(url) }
            return true
        }
    }

    /// Action rows run their action and keep the current page selected.
    private func select(_ item: SidebarItem?) {
        switch item {
        case .openEpisode:
            Task { @MainActor in app.presentOpenPanel() }
        case .recent(let id):
            guard let project = app.recentProjects.first(where: { $0.id == id }) else { return }
            guard FileManager.default.fileExists(atPath: project.mediaPath) else {
                app.alert = AppAlert(title: "Arquivo não encontrado", message: "“\(project.mediaPath)” foi movido ou apagado.")
                return
            }
            app.open(project.mediaURL)
        default:
            app.selection = item
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.selection ?? .overview {
        case .overview, .subtitles, .dubbing, .openEpisode, .recent:
            if let workspace = app.workspace {
                WorkspaceView(workspace: workspace, mode: mode).id(workspace.url)
            } else {
                WelcomeView()
            }
        case .library: LibraryView()
        case .queue: QueueView()
        }
    }

    private var mode: WorkspaceMode {
        switch app.selection {
        case .subtitles: .subtitles
        case .dubbing: .dubbing
        default: .overview
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            VStack(spacing: Theme.Spacing.s) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                Text("Anime Localization Studio").font(.largeTitle.weight(.semibold))
                Text("Abra um episódio para ver as faixas e então legendar (corrigir ou traduzir uma legenda) ou dublar.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: Theme.Spacing.m) {
                Button { app.presentOpenPanel() } label: {
                    Label("Abrir vídeo…", systemImage: "film").frame(minWidth: 150)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut("o", modifiers: .command)
                Button { app.selection = .library } label: {
                    Label("Abrir temporada…", systemImage: "square.stack.3d.up").frame(minWidth: 150)
                }
                .buttonStyle(.glass)
                .controlSize(.extraLarge)
            }
            steps
            if !app.missingTools.isEmpty {
                InlineMessage(kind: .warning, text: "Faltam ferramentas: \(app.missingTools.map(\.tool.rawValue).joined(separator: ", ")). Veja Ajustes › Diagnóstico para instalar.")
                    .frame(maxWidth: 520)
            }
            Text("Você também pode arrastar um vídeo ou uma pasta para esta janela.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paneBackground()
        .navigationTitle("Anime Localization Studio")
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            step("1", "Abrir", "MKV, MP4 ou MOV. A Visão geral mostra codecs, faixas e faixas padrão, sem tocar no arquivo.")
            step("2", "Legendar", "Corrija uma legenda existente ou crie uma tradução a partir dela, preservando estilos e tags.")
            step("3", "Dublar", "A legenda traduzida vira uma faixa de áudio com as vozes dos personagens.")
            step("4", "Gravar", "Novo arquivo ou o próprio, verificado e sem recodificar o vídeo.")
        }
        .frame(maxWidth: 760)
    }

    private func step(_ number: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(number)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: .circle)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
