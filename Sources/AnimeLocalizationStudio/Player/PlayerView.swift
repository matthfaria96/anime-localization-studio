import AVFoundation
import AppKit
import ASSRendering
import SubtitleKit
import SwiftUI

enum OverlayMode: String, CaseIterable, Identifiable {
    case translation, original, both, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .translation: "Tradução"
        case .original: "Original"
        case .both: "Original e tradução"
        case .none: "Sem legenda"
        }
    }
}

struct PlayerView: View {
    @Bindable var workspace: WorkspaceModel
    var player: PlayerModel { workspace.player }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let rect = videoRect(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    PlayerLayerView(player: player.player)
                    overlays(rect: rect)
                    if workspace.overlayMode == .original || workspace.overlayMode == .translation {
                        PositionHandle(workspace: workspace, rect: rect)
                    }
                    stateOverlay
                }
                .clipShape(.rect(cornerRadius: Theme.Radius.medium))
                .contentShape(.rect)
                .onTapGesture { player.togglePlay() }
            }
            .aspectRatio(max(0.5, player.videoSize.width / max(1, player.videoSize.height)), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Vídeo")
            .accessibilityHint("Clique para reproduzir ou pausar")
            TransportBar(workspace: workspace)
                .padding(.top, Theme.Spacing.s)
        }
    }

    @ViewBuilder
    private func overlays(rect: CGRect) -> some View {
        if workspace.usesFaithfulPreview, let original = workspace.originalRenderer, let translated = workspace.translationRenderer {
            faithful(rect: rect, original: original, translated: translated)
                .task(id: workspace.editor.revision) { await workspace.refreshRenderers() }
        } else {
            approximate(rect: rect)
        }
    }

    @ViewBuilder
    private func faithful(rect: CGRect, original: ASSRenderer, translated: ASSRenderer) -> some View {
        let time = player.currentTime
        let size = player.videoSize
        switch workspace.overlayMode {
        case .translation:
            LibassOverlay(renderer: translated, time: time, revision: workspace.renderRevision, videoRect: rect, videoSize: size)
        case .original:
            LibassOverlay(renderer: original, time: time, revision: workspace.renderRevision, videoRect: rect, videoSize: size)
        case .both:
            LibassOverlay(renderer: original, time: time, revision: workspace.renderRevision, videoRect: rect, videoSize: size)
                .opacity(0.6)
                .offset(y: -rect.height * 0.12)
            LibassOverlay(renderer: translated, time: time, revision: workspace.renderRevision, videoRect: rect, videoSize: size)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func approximate(rect: CGRect) -> some View {
        let editor = workspace.editor
        switch workspace.overlayMode {
        case .translation:
            SubtitleOverlay(cues: editor.activeCues(at: player.currentTime, in: .translation), document: editor.translation ?? editor.source, videoRect: rect)
        case .original:
            SubtitleOverlay(cues: editor.activeCues(at: player.currentTime, in: .original), document: editor.source, videoRect: rect)
        case .both:
            SubtitleOverlay(cues: editor.activeCues(at: player.currentTime, in: .original), document: editor.source, videoRect: rect)
                .opacity(0.65)
                .offset(y: -rect.height * 0.12)
            SubtitleOverlay(cues: editor.activeCues(at: player.currentTime, in: .translation), document: editor.translation ?? editor.source, videoRect: rect)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch player.state {
        case .idle:
            if workspace.info == nil { ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .preparing(let fraction, let message):
            VStack(spacing: Theme.Spacing.s) {
                ProgressView(value: fraction).frame(width: 220)
                Text(message).font(.callout).foregroundStyle(.white.opacity(0.85))
            }
            .padding(Theme.Spacing.l)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.large))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "play.slash").font(.largeTitle)
                Text("Pré-visualização indisponível").font(.headline)
                Text(message).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            EmptyView()
        }
    }

    private func videoRect(in size: CGSize) -> CGRect {
        let aspect = player.videoSize.width / max(1, player.videoSize.height)
        var width = size.width
        var height = width / aspect
        if height > size.height { height = size.height; width = height * aspect }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

private struct TransportBar: View {
    @Bindable var workspace: WorkspaceModel
    @State private var scrubbing: Double?
    var player: PlayerModel { workspace.player }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.xs) {
                Button("Fala anterior", systemImage: "backward.end.fill") { workspace.jumpLine(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option])
                    .hint("Fala anterior (⌥↑)", "Seleciona a fala anterior e leva o vídeo até ela.")
                Button(player.isPlaying ? "Pausar" : "Reproduzir", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [.option])
                    .hint("Reproduzir ou pausar (⌥Espaço)", "Toca ou pausa o vídeo. Clicar no vídeo também funciona.")
                    .font(.title3)
                    .frame(width: 30)
                Button("Próxima fala", systemImage: "forward.end.fill") { workspace.jumpLine(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option])
                    .hint("Próxima fala (⌥↓)", "Seleciona a próxima fala e leva o vídeo até ela.")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            Text(SubtitleTime.formatDisplay(Int(scrubbing ?? Double(player.currentTime))))
                .font(.callout.monospacedDigit())
                .frame(minWidth: 52, alignment: .trailing)
            Slider(value: Binding(get: { scrubbing ?? Double(player.currentTime) }, set: { scrubbing = $0 }),
                   in: 0...Double(max(1, player.duration))) { editing in
                if !editing, let value = scrubbing { player.seek(to: Int(value)); scrubbing = nil }
            }
            .controlSize(.small)
            .accessibilityLabel("Posição")
            .hint("Posição no vídeo", "Arraste para ir a outro ponto do episódio.")
            Text(SubtitleTime.formatDisplay(player.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)

            if !workspace.isEditingOriginal {
                Picker("Legenda no vídeo", selection: $workspace.overlayMode) {
                    ForEach(OverlayMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 70, maxWidth: 170)
                .hint("Legenda no vídeo", "Escolhe o que aparece sobre o vídeo: a tradução, o original, os dois ao mesmo tempo ou nada.")
            }

            if workspace.audioTracks.count > 1 {
                Picker("Áudio", selection: Binding(get: { workspace.previewAudioTrackID }, set: { workspace.selectPreviewAudio($0) })) {
                    ForEach(workspace.audioTracks) { track in
                        Text("\(track.displayLanguage) · \(track.name ?? track.codec)").tag(Optional(track.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 70, maxWidth: 220)
                .hint("Áudio da pré-visualização", "Escolhe qual faixa de áudio do arquivo você ouve aqui. Não muda nada no arquivo.")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .glassEffect(.regular, in: .capsule)
        .disabled(player.state != .ready)
    }
}

/// Hosts the AVPlayerLayer directly (no system controls), so the subtitle overlay and the
/// app's own transport stay in charge.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError("not used") }
    }
}
