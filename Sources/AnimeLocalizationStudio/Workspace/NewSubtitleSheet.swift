import SwiftUI

/// Novo › Legenda: a blank subtitle with the name and language it will have in the video.
struct NewSubtitleSheet: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var language = "pt-BR"
    @State private var nameEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Nova legenda").font(.title2.weight(.semibold))
                Text("Começa em branco, para escrever do zero. Ela vira uma faixa nova quando você salvar no vídeo.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Nome", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    .hint("Nome da legenda", "O nome que os players mostram no menu de legendas.")
                Picker("Idioma", selection: $language) {
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .hint("Idioma da legenda", "O idioma gravado na faixa, para os players escolherem a legenda certa.")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Criar") {
                    dismiss()
                    workspace.requestNewSubtitle(.blank(language: language, name: name.trimmingCharacters(in: .whitespaces)))
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 440)
        .onAppear {
            language = workspace.app.settings.targetLanguage
            name = Languages.name(for: language)
        }
        // The name follows the language until the person types one.
        .onChange(of: language) { if !nameEdited { name = Languages.name(for: language) } }
    }
}
