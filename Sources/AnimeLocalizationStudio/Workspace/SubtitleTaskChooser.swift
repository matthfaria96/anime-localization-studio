import MediaKit
import StudioCore
import SwiftUI

/// First step of Legendar: fix a subtitle that already exists, or make a translation from one.
/// The editor that follows is laid out for the choice.
struct SubtitleTaskChooser: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app

    private var textTracks: [MediaTrack] { workspace.subtitleTracks.filter { $0.textSubtitleExtension != nil } }
    private var target: String { Locale.current.localizedString(forIdentifier: app.settings.targetLanguage) ?? app.settings.targetLanguage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("O que você quer fazer com a legenda?").font(.largeTitle.weight(.semibold))
                    Text("A tela de edição se ajusta à escolha. Para trocar depois, use “Voltar”.")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: Theme.Spacing.l) {
                    choice(.edit, title: "Editar uma legenda existente", systemImage: "pencil.line",
                           detail: "Corrija erros de digitação, tempos e estilos de uma legenda do arquivo. Ao salvar, ela entra no MKV no lugar da antiga, com o mesmo idioma e nome.")
                        .hint("Editar uma legenda existente", "Uma coluna só, com o texto da legenda escolhida. Nada é traduzido.")
                    choice(.translate, title: "Criar uma tradução", systemImage: "translate",
                           detail: "Use uma legenda do arquivo (inglês, japonês, espanhol…) como base e crie uma tradução para \(target), lado a lado com o original. Ao final, ela vira uma faixa nova no MKV.")
                        .hint("Criar uma tradução", "Original e tradução lado a lado. Traduza tudo com um clique ou à mão, e incorpore como nova faixa.")
                }
                tracksPanel
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
    }

    private func choice(_ task: SubtitleTask, title: String, systemImage: String, detail: String) -> some View {
        Button {
            workspace.chooseSubtitleTask(task)
            Task { await workspace.reload() }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Image(systemName: systemImage).font(.system(size: 30)).foregroundStyle(.tint).frame(height: 40, alignment: .leading)
                Text(title).font(.title3.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                if task == .translate, workspace.editor.translation != nil {
                    Label("Já existe uma tradução: \(workspace.editor.translatedCount) de \(workspace.editor.translatableCount) falas", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(Theme.translated)
                }
                Spacer(minLength: 0)
                Label("Escolher", systemImage: "arrow.right").font(.callout.weight(.semibold)).foregroundStyle(.tint)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(.separator))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var tracksPanel: some View {
        Panel {
            SectionLabel("Legendas deste arquivo", systemImage: "captions.bubble")
            if workspace.subtitleTracks.isEmpty {
                Text("O arquivo não tem legendas. Depois de escolher, você pode abrir um arquivo de legenda (ASS, SSA ou SRT) ou transcrever o áudio no próprio Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(workspace.subtitleTracks) { track in
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "captions.bubble").foregroundStyle(.secondary).frame(width: 18)
                    Text(track.name ?? track.displayLanguage).lineLimit(1)
                    Tag(text: track.displayLanguage.uppercased())
                    Text(track.isBitmapSubtitle ? "\(track.codec) · imagem, precisa de OCR" : track.codec).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if track.id == workspace.project.sourceTrackID && workspace.project.externalSubtitlePath == nil {
                        Tag(text: "Escolhida como base", tint: .accentColor)
                    }
                }
            }
            if !textTracks.isEmpty {
                Text("A legenda base pode ser trocada depois, no painel da direita da edição.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
