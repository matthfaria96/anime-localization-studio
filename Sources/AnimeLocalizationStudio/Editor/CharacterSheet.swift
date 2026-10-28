import SwiftUI

/// Sets who speaks in the selected lines at once, suggesting the names already used.
struct CharacterSheet: View {
    let editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Quem fala \(editor.selection.count == 1 ? String(localized: "nesta fala") : String(localized: "nestas \(editor.selection.count) falas"))?").font(.title3.weight(.semibold))
            TextField("Nome do personagem", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(apply)
            if !editor.actorNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(editor.actorNames, id: \.self) { actor in
                            Button(actor) { name = actor }.controlSize(.small)
                        }
                    }
                }
            }
            Text(editor.source?.storesActorsInFile == false
                 ? "Esta legenda é SRT, que não tem campo de personagem: o nome fica guardado no app e o arquivo não muda."
                 : "O nome vai no campo “Name” do ASS, que nunca aparece na tela. ⌘Z desfaz.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Definir", action: apply).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 440)
        .onAppear {
            let current = Set(editor.rows.filter { editor.selection.contains($0.id) }.map(\.actor))
            if current.count == 1 { name = current.first ?? "" }
        }
    }

    private func apply() {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        editor.setActors(Dictionary(uniqueKeysWithValues: editor.selection.map { ($0, value) }), undoManager: undoManager)
        dismiss()
    }
}
