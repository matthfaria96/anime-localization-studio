import StudioCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                Section("Estúdio") {
                    Label(app.workspace?.title ?? "Episódio", systemImage: "film").tag(SidebarItem.workspace)
                    Label("Biblioteca", systemImage: "square.stack.3d.up").tag(SidebarItem.library)
                    Label("Fila", systemImage: "list.bullet.clipboard").tag(SidebarItem.queue)
                        .badge(app.queue.pendingCount)
                }
                Section("Consistência") {
                    Label("Séries e glossários", systemImage: "books.vertical").tag(SidebarItem.series)
                }
                Section("Sistema") {
                    Label("Diagnóstico", systemImage: "stethoscope").tag(SidebarItem.diagnostics)
                        .badge(app.missingTools.count)
                }
                if !app.recentProjects.isEmpty {
                    Section("Recentes") {
                        ForEach(app.recentProjects.prefix(8)) { project in
                            Button { app.open(project.mediaURL) } label: {
                                HStack {
                                    StatusDot(color: project.translationStatus == .muxed ? Theme.translated : project.translationStatus == .new ? .secondary.opacity(0.4) : .accentColor)
                                    Text(project.title).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .hintVerbatim(project.title, project.mediaPath)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .task { await app.refreshTools() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.hasDirectoryPath { app.library.add(url); app.selection = .library } else { app.open(url) }
            return true
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.selection ?? .workspace {
        case .workspace:
            if let workspace = app.workspace {
                WorkspaceView(workspace: workspace).id(workspace.url)
            } else {
                WelcomeView()
            }
        case .library: LibraryView()
        case .queue: QueueView()
        case .series: SeriesView()
        case .diagnostics: DiagnosticsView()
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
                Text("Abra um episódio para editar a legenda, traduzir tudo para o português e criar um novo MKV com a faixa incorporada.")
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
                InlineMessage(kind: .warning, text: "Faltam ferramentas: \(app.missingTools.map(\.tool.rawValue).joined(separator: ", ")). Veja Diagnóstico para instalar.")
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
            step("1", "Abrir", "MKV, MP4 ou MOV. As faixas são lidas sem tocar no arquivo.")
            step("2", "Traduzir", "Um clique traduz o episódio preservando estilos, tags e karaokê.")
            step("3", "Revisar", "Compare original e tradução sobre o vídeo e ajuste falas e tempos.")
            step("4", "Incorporar", "Novo MKV com a faixa em português, verificado e sem recodificar.")
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
