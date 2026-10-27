import MediaKit
import StudioCore
import SwiftUI

/// Makes a subtitle from the speech of the video: which audio, which language is spoken, and
/// optionally who speaks and a translation right after.
struct FromAudioSheet: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var audioTrack: Int?
    @State private var spokenLanguage = "ja-JP"
    @State private var identifySpeakers = true
    @State private var translateAfter = false
    @State private var language = "pt-BR"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Criar legenda a partir do áudio").font(.title2.weight(.semibold))
                Text("O app ouve o vídeo e escreve o que é dito, no tempo de cada fala, no idioma falado. Tudo no Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                if workspace.audioTracks.count > 1 {
                    Picker("Áudio", selection: $audioTrack) {
                        ForEach(workspace.audioTracks) { Text(WorkspaceModel.describe($0)).tag(Optional($0.id)) }
                    }
                    .hint("Áudio", "A faixa de áudio que será ouvida. Use a do idioma original.")
                }
                Picker("Idioma falado", selection: $spokenLanguage) {
                    ForEach(TranscriptionLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .hint("Idioma falado", "O idioma em que os personagens falam. A legenda sai nesse idioma.")
                Toggle("Identificar quem fala", isOn: $identifySpeakers)
                    .hint("Identificar quem fala", "Marca “Falante 1”, “Falante 2”… em cada fala, pelo som da voz. Ajuda na dublagem.")
                Toggle("Depois traduzir", isOn: $translateAfter)
                    .hint("Depois traduzir", "Quando a transcrição terminar, cria a tradução a partir dela.")
                if translateAfter {
                    Picker("Para", selection: $language) {
                        ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Na primeira vez, o macOS pode pedir para baixar o modelo de reconhecimento do idioma.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Criar legenda") {
                    dismiss()
                    workspace.requestNewSubtitle(.fromAudio(FromAudioRequest(spokenLanguage: spokenLanguage, audioTrackID: audioTrack,
                                                                             identifySpeakers: identifySpeakers,
                                                                             translateTo: translateAfter ? language : nil)))
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(workspace.audioTracks.isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 480)
        .onAppear {
            audioTrack = workspace.dubAudioTrack?.id
            language = app.settings.targetLanguage
        }
    }
}
