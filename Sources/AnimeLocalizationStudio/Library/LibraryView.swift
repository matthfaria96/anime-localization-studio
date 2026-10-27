import StudioCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var seriesID: UUID?

    var library: LibraryModel { app.library }

    var body: some View {
        Group {
            if library.folders.isEmpty {
                EmptyStateView(title: "Sua biblioteca está vazia",
                               message: "Adicione a pasta de uma temporada, série ou coleção de filmes para traduzir vários episódios de uma vez.",
                               systemImage: "square.stack.3d.up") {
                    Button("Adicionar pasta…", action: addFolder).buttonStyle(.glassProminent).controlSize(.large)
                }
            } else {
                table
            }
        }
        .navigationTitle("Biblioteca")
        .navigationSubtitle(library.items.isEmpty ? "" : "\(library.items.count) vídeos")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Adicionar pasta…", systemImage: "folder.badge.plus", action: addFolder)
                    .hint("Adicionar pasta", "Adiciona a pasta de uma série, temporada ou coleção de filmes à biblioteca.")
                Button("Atualizar", systemImage: "arrow.clockwise") { Task { await library.scan() } }
                    .hint("Atualizar", "Procura de novo os vídeos nas pastas da biblioteca.")
                    .disabled(library.isScanning)
            }
        }
        .task { if library.items.isEmpty && !library.folders.isEmpty { await library.scan() } }
        .onAppear { library.refreshStatuses() }
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table(library.items, selection: Binding(get: { library.selection }, set: { library.selection = $0 })) {
                TableColumn("Nome") { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).lineLimit(1)
                        if !item.relativeFolder.isEmpty { Text(item.relativeFolder).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                TableColumn("Tradução") { item in StatusLabel(status: item.project?.translationStatus ?? .new) }
                    .width(min: 120, ideal: 150, max: 200)
                TableColumn("Dublagem") { item in StatusLabel(status: item.project?.dubbingStatus ?? .new) }
                    .width(min: 90, ideal: 110, max: 160)
                TableColumn("Tamanho") { item in
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80, max: 100)
            }
            .contextMenu(forSelectionType: LibraryItem.ID.self) { ids in
                Button("Abrir no estúdio") { if let id = ids.first { app.open(URL(fileURLWithPath: id)) } }
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) }) }
            } primaryAction: { ids in
                if let id = ids.first { app.open(URL(fileURLWithPath: id)) }
            }
            Divider()
            batchBar
        }
    }

    private var batchBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            Menu {
                ForEach(library.folders, id: \.self) { folder in
                    Button("Remover “\(folder.lastPathComponent)” da biblioteca") { library.remove(folder) }
                }
            } label: {
                Label("\(library.folders.count) pastas", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Picker("Série", selection: $seriesID) {
                Text("Sem glossário").tag(UUID?.none)
                ForEach(app.series) { Text($0.name).tag(Optional($0.id)) }
            }
            .fixedSize()
            .hint("Série", "O glossário, as notas e o elenco de vozes dessa série são usados em todos os episódios selecionados.")
            Button("Traduzir \(library.selection.count) selecionados") {
                app.queue.enqueue(.translate, mediaURLs: library.selectedURLs, seriesID: seriesID)
                app.selection = .queue
            }
            .disabled(library.selection.isEmpty)
            .hint("Traduzir selecionados", "Coloca os episódios selecionados na fila para traduzir. A fila continua mesmo se o app for fechado.")
            Button("Traduzir e dublar") {
                app.queue.enqueue(.dub, mediaURLs: library.selectedURLs, seriesID: seriesID)
                app.selection = .queue
            }
            .disabled(library.selection.isEmpty)
            .hint("Traduzir e dublar", "Coloca os episódios selecionados na fila: traduz o que falta e dubla com o elenco da série escolhida.")
            Button("Traduzir e incorporar") {
                app.queue.enqueue(.translateAndMux, mediaURLs: library.selectedURLs, seriesID: seriesID)
                app.selection = .queue
            }
            .buttonStyle(.glassProminent)
            .disabled(library.selection.isEmpty)
            .hint("Traduzir e incorporar", "Traduz os episódios selecionados e cria para cada um o MKV com a legenda em português.")
        }
        .padding(Theme.Spacing.m)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adicionar"
        panel.message = "Escolha pastas de séries, temporadas ou filmes"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(library.add)
    }
}

struct StatusLabel: View {
    let status: WorkStatus

    var body: some View {
        Label {
            Text(status.label)
        } icon: {
            StatusDot(color: color)
        }
        .font(.callout)
        .foregroundStyle(status == .new ? .secondary : .primary)
    }

    private var color: Color {
        switch status {
        case .new: .secondary.opacity(0.4)
        case .extracted, .translating: .accentColor
        case .translated, .reviewed: Theme.translated.opacity(0.7)
        case .muxed: Theme.translated
        case .failed: Theme.failure
        }
    }
}
