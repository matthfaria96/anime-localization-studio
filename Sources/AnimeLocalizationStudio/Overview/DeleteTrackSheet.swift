import MediaKit
import SwiftUI

/// Confirms deleting one audio or subtitle track: what it is, what depends on it, the fonts only
/// it used (fonts belong to the whole file), and where to write the result.
struct DeleteTrackSheet: View {
    @Bindable var workspace: WorkspaceModel
    let track: MediaTrack
    @Environment(\.dismiss) private var dismiss
    @State private var replaceOriginal = false
    @State private var orphanFonts: [MediaAttachment]?
    @State private var removeFonts = false

    private var title: String { track.name ?? track.kind.label }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Excluir \(track.kind == .audio ? "o áudio" : "a legenda") “\(title)”?").font(.title2.weight(.semibold))
                Text("\(track.kind.label) · \(Languages.display(track.displayLanguage)) · \(track.codec)").foregroundStyle(.secondary)
            }
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(warnings, id: \.self) { InlineMessage(kind: .warning, text: $0) }
                }
            }
            if track.kind == .subtitles { fonts }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Onde gravar").font(.headline)
                choice(false, "Criar um novo arquivo sem ela", "“\(workspace.title) [editado].mkv”, ao lado do original. O original não muda.")
                choice(true, "Excluir deste arquivo", "O arquivo é regravado sem a faixa (o vídeo não é recodificado), conferido, e a versão anterior vai para a Lixeira.")
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Excluir", role: .destructive) {
                    let fonts = removeFonts ? (orphanFonts ?? []) : []
                    dismiss()
                    workspace.deleteTrack(track, fonts: fonts, replaceOriginal: replaceOriginal)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .disabled(track.kind == .subtitles && orphanFonts == nil)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 520)
        .task { orphanFonts = track.kind == .subtitles ? await workspace.fontsOnlyUsed(by: track) : [] }
    }

    private var warnings: [String] {
        var list: [String] = []
        if track.isDefault { list.append("É a faixa padrão: os players vão abrir com outra.") }
        if track.kind == .audio && workspace.audioTracks.count == 1 { list.append("É o único áudio: o vídeo fica sem som.") }
        if track.kind == .subtitles && track.id == workspace.project.sourceTrackID {
            list.append("É a legenda aberta em Legendar: as alterações ainda não gravadas nela deixam de valer.")
        }
        if track.kind == .audio && track.id == workspace.dubAudioTrack?.id { list.append("É o áudio de base da dublagem: a dublagem passa a usar outro.") }
        return list
    }

    @ViewBuilder
    private var fonts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Fontes").font(.headline)
            Text("As fontes são do arquivo inteiro, não de uma legenda: duas legendas com a mesma fonte usam o mesmo anexo. Fontes que outra legenda usa nunca são excluídas.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let orphanFonts {
                if orphanFonts.isEmpty {
                    Text("Nenhuma fonte é usada só por esta legenda: todas ficam no arquivo.").font(.callout)
                } else {
                    Toggle(isOn: $removeFonts) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Também excluir \(Plural.count(orphanFonts.count, "fonte usada", "fontes usadas")) só por ela")
                            Text(orphanFonts.map(\.fileName).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .hint("Excluir as fontes só desta legenda", "Tira do arquivo as fontes que apenas esta legenda usa. Desligado, elas ficam no arquivo sem uso.")
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Conferindo quais fontes só esta legenda usa…").foregroundStyle(.secondary) }
            }
        }
    }

    private func choice(_ value: Bool, _ title: String, _ detail: String) -> some View {
        Button { replaceOriginal = value } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: replaceOriginal == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(replaceOriginal == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
