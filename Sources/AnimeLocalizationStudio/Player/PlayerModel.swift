import AVFoundation
import MediaKit
import Observation

/// Playback of the preview (the original for MP4/MOV, a cached remux for MKV).
@Observable
final class PlayerModel {
    enum State: Equatable {
        case idle
        case preparing(fraction: Double, message: String)
        case ready
        case failed(String)
    }

    let player = AVPlayer()
    var state: State = .idle
    /// Milliseconds.
    var currentTime = 0
    var duration = 0
    var isPlaying = false
    var videoSize = CGSize(width: 16, height: 9)
    var usesPreviewEncode = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var boundaryToken: Any?

    init() {
        player.allowsExternalPlayback = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ms = Int((time.seconds.isFinite ? time.seconds : 0) * 1_000)
                if ms != self.currentTime { self.currentTime = ms }
                let playing = self.player.timeControlStatus == .playing
                if playing != self.isPlaying { self.isPlaying = playing }
            }
        }
    }

    func prepare(info: MediaInfo, audioTrack: MediaTrack?, tools: ToolLocator, cache: URL) async {
        if PreviewProxy.canPlayDirectly(info.url) {
            await load(info.url)
            return
        }
        state = .preparing(fraction: 0, message: "Preparando pré-visualização (sem recodificar o vídeo)…")
        let proxy = PreviewProxy(tools: tools, cacheDirectory: cache)
        do {
            let (url, mode) = try await proxy.make(for: info, audioTrack: audioTrack) { value in
                Task { @MainActor in
                    guard case .preparing(_, let message) = self.state else { return }
                    self.state = .preparing(fraction: value, message: message)
                }
            }
            usesPreviewEncode = mode == .previewEncode
            await load(url)
        } catch {
            // A superseded preview (another audio track was chosen) must not overwrite the new one.
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func load(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            let (length, playable) = try await asset.load(.duration, .isPlayable)
            guard playable else {
                state = .failed("O AVFoundation não consegue reproduzir este arquivo.")
                return
            }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                videoSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            duration = Int(length.seconds * 1_000)
            let resume = currentTime
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            if resume > 0 { seek(to: resume) }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func togglePlay() {
        guard state == .ready else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func pause() { player.pause() }

    func seek(to milliseconds: Int) {
        let target = max(0, min(milliseconds, max(0, duration)))
        currentTime = target
        player.seek(to: CMTime(value: CMTimeValue(target), timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(by milliseconds: Int) { seek(to: currentTime + milliseconds) }

    /// Plays one line and pauses at its end (for reviewing timing).
    func play(from start: Int, to end: Int) {
        clearBoundary()
        seek(to: start)
        player.play()
        let boundary = NSValue(time: CMTime(value: CMTimeValue(end), timescale: 1_000))
        boundaryToken = player.addBoundaryTimeObserver(forTimes: [boundary], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.clearBoundary()
            }
        }
    }

    private func clearBoundary() {
        if let token = boundaryToken { player.removeTimeObserver(token) }
        boundaryToken = nil
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        state = .idle
    }
}
