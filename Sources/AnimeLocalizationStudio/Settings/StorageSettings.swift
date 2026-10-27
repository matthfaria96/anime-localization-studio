import StudioCore
import SwiftUI

/// Everything the app keeps on disk, by kind, with its size and a way to clear it.
struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [StorageInventory.Entry] = []
    @State private var measuring = false
    @State private var confirm: StorageInventory.Kind?
    @State private var message: String?

    private var inventory: StorageInventory { StorageInventory(paths: app.paths) }
    private var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Form {
            Section {
                ForEach(entries) { entry in
                    LabeledContent {
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).monospacedDigit()
                            Button("Apagar") { if entry.kind.losesWork { confirm = entry.kind } else { clear(entry.kind) } }
                                .disabled(entry.bytes == 0)
                                .hintVerbatim("Apagar \(entry.kind.title.lowercased())", entry.kind.detail)
                        }
                    } label: {
                        Text(entry.kind.title)
                        Text(entry.kind.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if entries.isEmpty { ProgressView() }
            } header: {
                HStack {
                    Text("Guardado pelo app: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    Spacer()
                    if measuring { ProgressView().controlSize(.small) }
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.paths.root]) }
                        .buttonStyle(.link)
                        .hint("Mostrar no Finder", "Abre a pasta de dados do app.")
                }
            } footer: {
                Text(message ?? "Os vídeos que você abriu e os arquivos que o app criou ao lado deles nunca são apagados aqui. Episódios abertos ou em processamento são pulados.")
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
        .confirmationDialog("Apagar os projetos?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Apagar projetos", role: .destructive) { if let kind = confirm { clear(kind) } }
        } message: {
            Text("As legendas extraídas, traduções e revisões de todos os episódios são apagadas. Traduções já incorporadas a um MKV continuam no arquivo de vídeo. O episódio aberto agora é mantido.")
        }
    }

    private func measure() async {
        measuring = true
        let inventory = inventory
        entries = await Task.detached(priority: .utility) { inventory.entries() }.value
        measuring = false
    }

    private func clear(_ kind: StorageInventory.Kind) {
        var busy = Set(app.activity.busy.keys)
        if kind == .projects, let open = app.workspace?.project.id { busy.insert(open) }
        do {
            try inventory.clear(kind, except: busy)
            message = "\(kind.title) apagados."
            if kind == .dubs { app.workspace?.voiceSamples = [:]; app.workspace?.refreshDubStorage() }
            if kind == .projects { app.refreshRecents() }
        } catch {
            message = "Não foi possível apagar tudo: \(error.localizedDescription)"
        }
        confirm = nil
        Task { await measure() }
    }
}
