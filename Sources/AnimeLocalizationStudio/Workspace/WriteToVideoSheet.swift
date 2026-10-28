import MediaKit
import SwiftUI

/// Salvar › Gravar no vídeo: how the subtitle goes into the MKV (its name and flags when it is
/// a new track) and where: a new file next to it, or this file.
struct WriteToVideoSheet: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var replace = false

    private var isTranslation: Bool { !workspace.isEditingOriginal }
    private var isNewSubtitle: Bool { workspace.isEditingOriginal && workspace.project.externalSubtitlePath != nil }
    private var replacedTrack: MediaTrack? {
        guard workspace.isEditingOriginal, !isNewSubtitle else { return nil }
        return workspace.subtitleTracks.first { $0.id == workspace.project.sourceTrackID }
    }
    private var suffix: String { isTranslation ? app.settings.targetLanguage.uppercased() : "editado" }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Gravar no vídeo").font(.title2.weight(.semibold))
            if isTranslation {
                Form {
                    TextField("Nome da faixa", text: $app.settings.trackName)
                        .hint("Nome da faixa", "O nome que os players mostram no menu de legendas.")
                    LabeledContent("Idioma", value: Languages.name(for: app.settings.targetLanguage))
                    Toggle("Ligada ao abrir o vídeo", isOn: $app.settings.makeDefault)
                        .hint("Legenda padrão", "Os players abrem o vídeo com esta legenda ligada.")
                    Toggle("Primeira da lista", isOn: $app.settings.placeNewTrackFirst)
                        .hint("Primeira da lista", "A faixa nova aparece no topo do menu de legendas do player.")
                }
                .formStyle(.grouped)
            } else if isNewSubtitle {
                Form {
                    TextField("Nome da faixa", text: Binding(get: { workspace.project.newTrackName ?? Languages.name(for: trackLanguage) },
                                                             set: { workspace.setNewTrackName($0) }))
                        .hint("Nome da faixa", "O nome que os players mostram no menu de legendas.")
                    Picker("Idioma", selection: Binding(get: { trackLanguage }, set: { workspace.setNewTrackLanguage($0) })) {
                        ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                        if !Languages.all.contains(where: { $0.code == trackLanguage }) { Text(Languages.name(for: trackLanguage)).tag(trackLanguage) }
                    }
                    .hint("Idioma da faixa", "O idioma gravado na faixa, para os players escolherem a legenda certa.")
                    Toggle("Ligada ao abrir o vídeo", isOn: $app.settings.makeDefault)
                        .hint("Legenda padrão", "Os players abrem o vídeo com esta legenda ligada.")
                }
                .formStyle(.grouped)
            } else {
                Text("A legenda corrigida entra no lugar de “\(replacedTrack?.name ?? replacedTrack?.codec ?? "faixa original")”, com o mesmo idioma, nome e flags. As outras faixas não mudam e o vídeo não é recodificado.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Onde gravar").font(.headline)
                ChoiceRow(title: "Criar um novo arquivo", selected: !replace, action: { replace = false }) {
                    Text("“\(workspace.title) [\(suffix)].mkv”, na mesma pasta. O original não muda.").font(.caption).foregroundStyle(.secondary)
                }
                ChoiceRow(title: "Gravar neste arquivo", selected: replace, action: { replace = true }) {
                    Text("O MKV é regravado (sem recodificar o vídeo), conferido, e só então substitui o original, que vai para a Lixeira.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Gravar") {
                    dismiss()
                    workspace.writeToVideo(replaceOriginal: replace)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 480)
    }

    private var trackLanguage: String { workspace.project.newTrackLanguage ?? app.settings.targetLanguage }
}
