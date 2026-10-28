import MediaKit
import SwiftUI

/// First page of a video: what the file is (size, codecs, tracks), which tracks open by
/// default, and extracting tracks.
struct OverviewView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if let operation = workspace.operation {
                    let cancel: (() -> Void)? = operation.kind == .loading ? nil : { workspace.cancelOperation() }
                    OperationProgress(message: operation.message, fraction: operation.fraction, onCancel: cancel)
                }
                if let notice = workspace.notice {
                    HStack {
                        InlineMessage(kind: notice.kind, text: notice.text)
                        if let action = workspace.noticeAction { Button(action.title, action: action.run).buttonStyle(.link) }
                    }
                }
                if let info = workspace.info {
                    FileFacts(info: info)
                    tracks(info)
                } else if workspace.operation == nil {
                    Text("Não foi possível ler as faixas.").foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .sheet(item: $workspace.trackToDelete) { track in DeleteTrackSheet(workspace: workspace, track: track) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(workspace.title).font(.largeTitle.weight(.semibold)).lineLimit(2)
            HStack(spacing: Theme.Spacing.s) {
                Text(workspace.url.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.url]) }
                    .buttonStyle(.link)
                    .hint("Mostrar no Finder", "Abre a pasta do arquivo com ele selecionado.")
                Spacer(minLength: Theme.Spacing.s)
                Button("Fechar vídeo", systemImage: "xmark.circle") { app.closeVideo() }
                    .disabled(workspace.isBusy)
                    .hint("Fechar vídeo", "Volta à tela inicial para abrir outro vídeo. O app trabalha com um vídeo por vez.")
            }
        }
    }

    // MARK: Tracks

    private func tracks(_ info: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if !info.tracks(.video).isEmpty {
                Panel {
                    SectionLabel("Vídeo", systemImage: "film")
                    ForEach(info.tracks(.video)) { track in
                        TrackLine(track: track, detail: videoDetail(track)) { extractButton(track) }
                    }
                }
            }
            Panel {
                HStack {
                    SectionLabel("Áudio", systemImage: "waveform")
                    Spacer()
                    Text("Padrão = o áudio que os players tocam ao abrir o arquivo.").font(.caption).foregroundStyle(.secondary)
                }
                if info.tracks(.audio).isEmpty { Text("Sem faixas de áudio.").foregroundStyle(.secondary) }
                ForEach(info.tracks(.audio)) { track in
                    TrackLine(track: track, detail: audioDetail(track)) {
                        defaultButton(isDefault: workspace.effectiveDefaults.audioTrackID == track.id) {
                            var defaults = workspace.effectiveDefaults
                            defaults.audioTrackID = track.id
                            workspace.pendingDefaults = defaults
                        }
                        extractButton(track)
                        deleteButton(track)
                    }
                }
            }
            Panel {
                HStack {
                    SectionLabel("Legendas", systemImage: "captions.bubble")
                    Spacer()
                    Text("Padrão = a legenda que abre ligada.").font(.caption).foregroundStyle(.secondary)
                }
                if info.tracks(.subtitles).isEmpty { Text("Sem faixas de legenda.").foregroundStyle(.secondary) }
                ForEach(info.tracks(.subtitles)) { track in
                    TrackLine(track: track, detail: subtitleDetail(track)) {
                        defaultButton(isDefault: workspace.effectiveDefaults.subtitleTrackID == track.id) { setDefaultSubtitle(track.id) }
                        extractButton(track)
                        deleteButton(track)
                    }
                }
                if !info.tracks(.subtitles).isEmpty {
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "captions.bubble").foregroundStyle(.tertiary).frame(width: 20)
                        Text("Nenhuma legenda ligada ao abrir").foregroundStyle(.secondary)
                        Spacer()
                        defaultButton(isDefault: workspace.effectiveDefaults.subtitleTrackID == -1) { setDefaultSubtitle(-1) }
                        // Room of the Extrair… and trash buttons of the rows above, so the column lines up.
                        Color.clear.frame(width: 96, height: 1)
                        Image(systemName: "trash").hidden()
                    }
                    .padding(.vertical, Theme.Spacing.xxs)
                }
            }
            if workspace.hasPendingDefaults {
                HStack {
                    InlineMessage(kind: .info, text: String(localized: "Faixas padrão alteradas, ainda não gravadas no arquivo."))
                    Spacer()
                    Button("Descartar") { workspace.pendingDefaults = nil }
                        .hint("Descartar", "Volta às faixas padrão que o arquivo já tem.")
                    Button("Gravar faixas padrão…") { workspace.askDefaultsDestination = true }
                        .buttonStyle(.glassProminent)
                        .disabled(workspace.isBusy)
                        .hint("Gravar faixas padrão", "Você escolhe entre alterar o próprio arquivo (instantâneo, só o cabeçalho do MKV muda) ou criar uma cópia.")
                }
            }
            if !info.attachments.isEmpty {
                Panel {
                    SectionLabel("Anexos", systemImage: "paperclip")
                    HStack {
                        Text(attachmentsText(info))
                        Spacer()
                        if info.attachments.contains(where: \.isFont) {
                            Button("Extrair todas as fontes…", systemImage: "textformat") { workspace.extractFonts() }
                                .controlSize(.small)
                                .disabled(workspace.isBusy)
                                .hint("Extrair todas as fontes", "Salva de uma vez, numa pasta que você escolhe, todas as fontes anexadas ao vídeo. O vídeo não muda.")
                        }
                    }
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func attachmentsText(_ info: MediaInfo) -> String {
        let fonts = info.attachments.filter(\.isFont).count
        let others = info.attachments.count - fonts
        let parts = [fonts > 0 ? Plural.count(fonts, "fonte", "fontes") : nil, others > 0 ? Plural.count(others, "outro anexo", "outros anexos") : nil]
        return parts.compactMap { $0 }.joined(separator: " e ") + String(localized: ". Mantidos em tudo o que o app grava.")
    }

    private func setDefaultSubtitle(_ id: Int) {
        var defaults = workspace.effectiveDefaults
        defaults.subtitleTrackID = id
        workspace.pendingDefaults = defaults
    }

    private func defaultButton(isDefault: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if isDefault {
                Label("Padrão", systemImage: "checkmark.circle.fill").foregroundStyle(.tint).font(.callout.weight(.medium))
                    .frame(width: 120, alignment: .leading)
                    .hint("Faixa padrão", "Esta faixa abre ligada nos players.")
            } else {
                Button("Tornar padrão", action: action)
                    .controlSize(.small)
                    .frame(width: 120, alignment: .leading)
                    .disabled(workspace.isBusy)
                    .hint("Tornar padrão", "Marca esta faixa para abrir ligada. A mudança só vai para o arquivo quando você clicar em “Gravar faixas padrão”.")
            }
        }
    }

    private func deleteButton(_ track: MediaTrack) -> some View {
        Button("Excluir…", systemImage: "trash") { workspace.trackToDelete = track }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(workspace.isBusy)
            .hint("Excluir faixa", "Tira esta faixa do vídeo. Antes, mostra o que depende dela e pergunta: novo arquivo ou este arquivo.")
    }

    private func extractButton(_ track: MediaTrack) -> some View {
        Button("Extrair…", systemImage: "square.and.arrow.up") { workspace.extractTrack(track) }
            .controlSize(.small)
            .frame(width: 96, alignment: .trailing)
            .disabled(workspace.isBusy)
            .hint("Extrair faixa", "Salva esta faixa como um arquivo separado (.\(track.nativeFileExtension)), sem converter. O arquivo original não muda.")
    }

    private func videoDetail(_ track: MediaTrack) -> String {
        [track.codec, track.width.map { "\($0)×\(track.height ?? 0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func audioDetail(_ track: MediaTrack) -> String {
        let channels: String? = track.channels.map {
            switch $0 {
            case 1: "mono"
            case 2: String(localized: "estéreo")
            case 6: "5.1"
            case 8: "7.1"
            default: "\($0) canais"
            }
        }
        let rate = track.sampleRate.map { "\(($0 + 500) / 1_000) kHz" }
        return [track.codec, channels, rate].compactMap { $0 }.joined(separator: " · ")
    }

    private func subtitleDetail(_ track: MediaTrack) -> String {
        var parts = [track.codec, track.isBitmapSubtitle ? String(localized: "imagem (OCR para editar)") : String(localized: "texto")]
        if track.isForced { parts.append(String(localized: "forçada")) }
        return parts.joined(separator: " · ")
    }
}

/// One track: icon, name, language and codec, then its buttons.
private struct TrackLine<Trailing: View>: View {
    let track: MediaTrack
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("\(track.id)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(track.name ?? track.kind.label).lineLimit(1)
                    Tag(text: Languages.display(track.displayLanguage))
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.s)
            trailing
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .hintVerbatim(track.name ?? track.kind.label, String(localized: "Faixa \(track.id) · \(track.kind.label) · \(track.codec) · idioma \(track.displayLanguage)"))
    }
}

/// Size, length and what the file contains, at a glance.
private struct FileFacts: View {
    let info: MediaInfo

    var body: some View {
        Panel {
            SectionLabel("Arquivo", systemImage: "doc")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)], alignment: .leading, spacing: Theme.Spacing.m) {
                fact(String(localized: "Tamanho"), ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
                fact(String(localized: "Duração"), info.durationMilliseconds.map { Duration.milliseconds($0).formatted(.time(pattern: .hourMinuteSecond)) } ?? "—")
                fact(String(localized: "Contêiner"), info.container)
                if let video = info.tracks(.video).first {
                    fact(String(localized: "Vídeo"), [video.codec, video.width.map { "\($0)×\(video.height ?? 0)" }].compactMap { $0 }.joined(separator: " · "))
                }
                fact(String(localized: "Áudios"), "\(info.tracks(.audio).count)")
                fact(String(localized: "Legendas"), "\(info.tracks(.subtitles).count)")
                fact(String(localized: "Capítulos"), "\(info.chapterCount)")
                fact(String(localized: "Fontes anexadas"), "\(info.attachments.filter(\.isFont).count)")
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled)
        }
    }
}
