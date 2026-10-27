import StudioCore
import SwiftUI
import TranslationKit

/// Series and their glossaries: names, techniques, places and how characters address each
/// other, shared by every episode so a season stays consistent.
struct SeriesView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedID: UUID?
    @State private var draft: Series?
    @State private var entrySelection: Set<GlossaryEntry.ID> = []

    var body: some View {
        HSplitView {
            List(app.series, selection: $selectedID) { series in
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.name)
                    Text("\(series.glossary.entries.count) termos").font(.caption).foregroundStyle(.secondary)
                }
                .tag(series.id)
                .contextMenu { Button("Excluir série", role: .destructive) { app.deleteSeries(series.id) } }
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
            .overlay {
                if app.series.isEmpty {
                    Text("Crie uma série para guardar o glossário da temporada.").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding()
                }
            }
            editor.frame(minWidth: 480, maxWidth: .infinity)
        }
        .navigationTitle("Séries e glossários")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Nova série", systemImage: "plus") {
                    let series = Series(name: "Nova série")
                    app.saveSeries(series)
                    selectedID = series.id
                }
            }
        }
        .onChange(of: selectedID) { _, id in draft = app.series.first { $0.id == id } }
        .onAppear { if selectedID == nil { selectedID = app.series.first?.id } }
    }

    @ViewBuilder
    private var editor: some View {
        if let binding = Binding($draft) {
            Form {
                Section {
                    TextField("Nome", text: binding.name)
                    Toggle("Manter honoríficos (-san, -kun, -chan, -senpai…)", isOn: binding.glossary.keepHonorifics)
                        .hint("Honoríficos", "Ligado: a tradução mantém -san, -kun, -chan… como no original. Desligado: adapta para o português.")
                } header: { Text("Série") }
                Section {
                    TextEditor(text: binding.glossary.notes)
                        .font(.callout)
                        .frame(minHeight: 90)
                } header: {
                    Text("Notas para o tradutor")
                } footer: {
                    Text("Sinopse, personagens, quem trata quem por “você” ou “senhor”, tom da obra. Enviadas aos motores que usam contexto.")
                }
                Section {
                    Table(binding.glossary.entries, selection: $entrySelection) {
                        TableColumn("Original") { $entry in TextField("Original", text: $entry.source).labelsHidden() }
                        TableColumn("Tradução") { $entry in TextField("Tradução", text: $entry.target).labelsHidden() }
                        TableColumn("Tipo") { $entry in
                            Picker("Tipo", selection: $entry.kind) {
                                ForEach(GlossaryEntry.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                        }
                        .width(min: 110, ideal: 120)
                        TableColumn("Nota") { $entry in TextField("Nota", text: $entry.note).labelsHidden() }
                    }
                    .frame(minHeight: 220)
                    HStack {
                        Button("Adicionar termo", systemImage: "plus") {
                            binding.wrappedValue.glossary.entries.append(GlossaryEntry(source: "", target: ""))
                        }
                        Button("Remover", systemImage: "minus") {
                            binding.wrappedValue.glossary.entries.removeAll { entrySelection.contains($0.id) }
                            entrySelection = []
                        }
                        .disabled(entrySelection.isEmpty)
                        .hint("Remover", "Apaga do glossário os termos selecionados.")
                        Spacer()
                        Button("Salvar") { save() }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut("s", modifiers: .command)
                            .hint("Salvar (⌘S)", "Grava o glossário e as notas. Eles passam a valer nas próximas traduções desta série.")
                            .disabled(binding.wrappedValue == app.series.first { $0.id == draft?.id })
                    }
                } header: {
                    Text("Glossário")
                } footer: {
                    Text("Para manter um nome igual, repita-o em “Tradução”. O relatório da tradução avisa quando um termo não foi respeitado.")
                }
            }
            .formStyle(.grouped)
        } else {
            EmptyStateView(title: "Nenhuma série selecionada", message: "Escolha uma série à esquerda ou crie uma nova.", systemImage: "books.vertical") {
                EmptyView()
            }
        }
    }

    private func save() {
        guard var value = draft else { return }
        value.glossary.entries.removeAll { $0.source.trimmingCharacters(in: .whitespaces).isEmpty }
        app.saveSeries(value)
        draft = value
    }
}
