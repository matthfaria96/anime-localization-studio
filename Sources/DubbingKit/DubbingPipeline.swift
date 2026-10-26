import CryptoKit
import Foundation
import MediaKit

public enum DubbingMode: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// The new voice talks over the original, which is lowered under it.
    case voiceOver
    /// The original dialogue is removed (on-device separation) and the new voice takes its place.
    case replaceDialogue

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .voiceOver: "Voice-over"
        case .replaceDialogue: "Substituir falas"
        }
    }
    public var trackSuffix: String { self == .voiceOver ? "voice-over" : "falas substituídas" }
}

public struct DubbingOptions: Sendable, Hashable, Codable {
    /// Largest speed-up applied to a line that does not fit its slot.
    public var maxSpeedup: Double
    /// Voice used for speakers without a cast member (and for unknown speakers).
    public var defaultVoice: String?
    public var mode: DubbingMode

    public init(maxSpeedup: Double = 1.3, defaultVoice: String? = nil, mode: DubbingMode = .voiceOver) {
        self.maxSpeedup = maxSpeedup
        self.defaultVoice = defaultVoice
        self.mode = mode
    }
}

public struct DubbingReport: Sendable, Hashable, Codable {
    public var engine: String
    public var totalSegments: Int
    public var synthesized: Int
    public var reusedClips: Int
    /// Lines sped up to fit their time.
    public var spedUp: [Int]
    /// Lines still longer than their time after the maximum speed-up.
    public var overflowing: [Int]
    /// Lines moved later so they would not overlap the previous one.
    public var delayed: [Int]
    public var failed: [Int: String]
    public var startedAt: Date
    public var finishedAt: Date

    public var problemLines: Set<Int> { Set(overflowing).union(delayed).union(failed.keys) }
}

/// Voice-over dub of an episode: synthesize every line with the cast's voices, fit each clip to
/// its slot, lay them on one voice track and mix it over the original audio with ducking.
/// Clips are cached by text, voice and engine, so an interrupted or repeated run only
/// synthesizes what changed. Replacing the original voices (instead of talking over them)
/// needs source separation, which is not part of this pipeline yet.
public struct DubbingPipeline: Sendable {
    public let synthesizer: any SpeechSynthesizer
    public let tools: ToolLocator
    public let workDirectory: URL
    public let cast: VoiceCast
    public let options: DubbingOptions

    public init(synthesizer: any SpeechSynthesizer, tools: ToolLocator, workDirectory: URL, cast: VoiceCast, options: DubbingOptions = DubbingOptions()) {
        self.synthesizer = synthesizer
        self.tools = tools
        self.workDirectory = workDirectory
        self.cast = cast
        self.options = options
    }

    public func run(_ segments: [DubSegment], media: MediaInfo, audioTrack: MediaTrack, output: URL,
                    progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> DubbingReport {
        let started = Date()
        let clips = workDirectory.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let mixer = AudioMixer(tools: tools)
        var report = DubbingReport(engine: synthesizer.id, totalSegments: segments.count, synthesized: 0, reusedClips: 0, spedUp: [],
                                   overflowing: [], delayed: [], failed: [:], startedAt: started, finishedAt: started)
        var placements: [AudioMixer.Placement] = []
        for (n, segment) in segments.enumerated() {
            try Task.checkCancellation()
            progress?(Double(n) / Double(max(1, segments.count)) * 0.8, "Gerando voz \(n + 1) de \(segments.count)…")
            let member = cast.member(for: segment.speaker)
            guard let voice = member?.voiceID ?? options.defaultVoice else {
                report.failed[segment.id] = "\(segment.speaker) não tem voz no elenco"
                continue
            }
            let speed = member?.speed ?? 1
            let key = Self.cacheKey(segment.text, voice: voice, style: member?.style, speed: speed, engine: synthesizer.id)
            let raw = clips.appendingPathComponent("\(key).wav")
            let fitted = clips.appendingPathComponent("\(key)-\(segment.slot).fit.wav")
            do {
                if FileManager.default.fileExists(atPath: raw.path) {
                    report.reusedClips += 1
                } else {
                    let partial = clips.appendingPathComponent(".\(key).\(UUID().uuidString.prefix(6)).wav")
                    try await synthesizer.synthesize(segment.text, voice: voice, style: member?.style, speed: speed, to: partial)
                    try FileOps.replaceItem(at: raw, with: partial)
                    report.synthesized += 1
                }
                let clip = try await mixer.fit(raw, slot: segment.slot, maxSpeedup: options.maxSpeedup, to: fitted)
                if clip.tempo > 1.001 { report.spedUp.append(segment.id) }
                if clip.overflows { report.overflowing.append(segment.id) }
                placements.append(.init(id: segment.id, url: clip.url, start: segment.start))
            } catch let error as SynthesisError {
                if case .engineUnavailable = error { throw error }
                report.failed[segment.id] = error.localizedDescription
            }
        }
        guard !placements.isEmpty else { throw SynthesisError.failed("nenhuma fala pôde ser gerada") }
        try Task.checkCancellation()
        progress?(0.82, "Montando a trilha de voz…")
        let voiceTrack = workDirectory.appendingPathComponent("voice.wav")
        let total = media.durationMilliseconds ?? (placements.map(\.start).max() ?? 0) + 10_000
        report.delayed = try mixer.assembleVoiceTrack(placements, totalDuration: total, to: voiceTrack)
        switch options.mode {
        case .voiceOver:
            progress?(0.85, "Mixando com o áudio original…")
            try await mixer.mixVoiceOver(media: media, audioTrack: audioTrack, voice: voiceTrack, to: output) { value in
                progress?(0.85 + value * 0.15, "Mixando com o áudio original…")
            }
        case .replaceDialogue:
            let background = try await removeDialogue(media: media, audioTrack: audioTrack, progress: progress)
            progress?(0.93, "Mixando as novas falas com a trilha…")
            try await mixer.mixReplacingDialogue(background: background, voice: voiceTrack, durationMilliseconds: media.durationMilliseconds, to: output) { value in
                progress?(0.93 + value * 0.07, "Mixando as novas falas com a trilha…")
            }
        }
        report.finishedAt = Date()
        return report
    }

    /// Original audio without its dialogue, cached in the work folder per source track.
    private func removeDialogue(media: MediaInfo, audioTrack: MediaTrack, progress: (@Sendable (Double, String) -> Void)?) async throws -> URL {
        let background = workDirectory.appendingPathComponent("background-\(audioTrack.id).wav")
        if FileManager.default.fileExists(atPath: background.path) { return background }
        let original = workDirectory.appendingPathComponent("original-\(audioTrack.id).wav")
        let isolated = workDirectory.appendingPathComponent("dialogue-\(audioTrack.id).wav")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: isolated)
        }
        progress?(0.86, "Extraindo o áudio original…")
        _ = try await TrackExtractor(tools: tools).extractAudioWAV(audioTrack, from: media, to: original)
        let partial = workDirectory.appendingPathComponent(".background-\(UUID().uuidString.prefix(6)).wav")
        try await VoiceSeparator(tools: tools).separate(original, voice: isolated, background: partial) { value in
            progress?(0.87 + value * 0.06, "Separando as falas da música e dos efeitos…")
        }
        try FileOps.replaceItem(at: background, with: partial)
        return background
    }

    static func cacheKey(_ text: String, voice: String, style: String?, speed: Double, engine: String) -> String {
        let material = [engine, voice, style ?? "", String(format: "%.3f", speed), text].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
