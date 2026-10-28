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
        case .replaceDialogue: String(localized: "Substituir falas")
        }
    }
    public var trackSuffix: String { self == .voiceOver ? "voice-over" : String(localized: "falas substituídas") }
}

public struct DubbingOptions: Sendable, Hashable, Codable {
    /// Largest speed-up applied to a line that does not fit its slot.
    public var maxSpeedup: Double
    /// Voice used for speakers without a cast member (and for unknown speakers).
    public var defaultVoice: String?
    public var mode: DubbingMode
    /// A voice for single lines (by segment id): the original audio of that line, so the clone
    /// keeps its emotion. With a character voice too, the reference is this clip followed by
    /// the character's sample (see `reference(line:character:in:)`).
    public var lineVoices: [Int: String] = [:]

    public init(maxSpeedup: Double = 1.3, defaultVoice: String? = nil, mode: DubbingMode = .voiceOver, lineVoices: [Int: String] = [:]) {
        self.maxSpeedup = maxSpeedup
        self.defaultVoice = defaultVoice
        self.mode = mode
        self.lineVoices = lineVoices
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
/// synthesizes what changed. Replacing the original voices separates the dialogue from the
/// music and effects first (`VoiceSeparator`).
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
            progress?(Double(n) / Double(max(1, segments.count)) * 0.8, String(localized: "Gerando voz \(n + 1) de \(segments.count)…"))
            let member = cast.member(for: segment.speaker)
            guard let voice = try await reference(line: options.lineVoices[segment.id], character: member?.voiceID ?? options.defaultVoice,
                                                  in: workDirectory) else {
                report.failed[segment.id] = String(localized: "\(segment.speaker) não tem voz no elenco")
                continue
            }
            let speed = member?.speed ?? 1
            let key = Self.cacheKey(segment.text, voice: voice, engine: synthesizer.id)
            let raw = clips.appendingPathComponent("\(key).wav")
            let fitted = clips.appendingPathComponent("\(key)-\(segment.slot)-\(String(format: "%.2f", speed)).fit.wav")
            do {
                if FileManager.default.fileExists(atPath: raw.path) {
                    report.reusedClips += 1
                } else {
                    let partial = clips.appendingPathComponent(".\(key).\(UUID().uuidString.prefix(6)).wav")
                    try await synthesizer.synthesize(segment.text, voice: voice, to: partial)
                    try FileOps.replaceItem(at: raw, with: partial)
                    report.synthesized += 1
                }
                let clip = try await mixer.fit(raw, slot: segment.slot, speed: speed, maxSpeedup: options.maxSpeedup, to: fitted)
                if clip.tempo > speed + 0.001 { report.spedUp.append(segment.id) }
                if clip.overflows { report.overflowing.append(segment.id) }
                placements.append(.init(id: segment.id, url: clip.url, start: segment.start))
            } catch let error as SynthesisError {
                if case .engineUnavailable = error { throw error }
                report.failed[segment.id] = error.localizedDescription
            }
        }
        guard !placements.isEmpty else { throw SynthesisError.failed(String(localized: "nenhuma fala pôde ser gerada")) }
        try Task.checkCancellation()
        progress?(0.82, String(localized: "Montando a trilha de voz…"))
        let voiceTrack = workDirectory.appendingPathComponent("voice.wav")
        let total = media.durationMilliseconds ?? (placements.map(\.start).max() ?? 0) + 10_000
        report.delayed = try mixer.assembleVoiceTrack(placements, totalDuration: total, to: voiceTrack)
        switch options.mode {
        case .voiceOver:
            progress?(0.85, String(localized: "Mixando com o áudio original…"))
            try await mixer.mixVoiceOver(media: media, audioTrack: audioTrack, voice: voiceTrack, to: output) { value in
                progress?(0.85 + value * 0.15, String(localized: "Mixando com o áudio original…"))
            }
        case .replaceDialogue:
            let background = try await removeDialogue(media: media, audioTrack: audioTrack, progress: progress)
            progress?(0.93, String(localized: "Mixando as novas falas com a trilha…"))
            try await mixer.mixReplacingDialogue(background: background, voice: voiceTrack, durationMilliseconds: media.durationMilliseconds, to: output) { value in
                progress?(0.93 + value * 0.07, String(localized: "Mixando as novas falas com a trilha…"))
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
        progress?(0.86, String(localized: "Extraindo o áudio original…"))
        _ = try await TrackExtractor(tools: tools).extractAudioWAV(audioTrack, from: media, to: original)
        let partial = workDirectory.appendingPathComponent(".background-\(UUID().uuidString.prefix(6)).wav")
        try await VoiceSeparator(tools: tools).separate(original, voice: isolated, background: partial) { value in
            progress?(0.87 + value * 0.06, String(localized: "Separando as falas da música e dos efeitos…"))
        }
        try FileOps.replaceItem(at: background, with: partial)
        return background
    }

    /// What a line is cloned from. A single line's clip is short (often 2 s), and the clone
    /// gets the timbre from up to 10 s of reference: measured with a speaker-recognition model
    /// (VoiceCloneEvaluation), the line alone sounded about half as much like the person as
    /// their 12 s sample (0.41 against 0.74). So the line's clip comes first, for its emotion,
    /// and the character's sample after it, for the voice (0.72). Joined once per pair.
    func reference(line: String?, character: String?, in directory: URL) async throws -> String? {
        guard let line, let character, line != character, FileManager.default.fileExists(atPath: character) else { return line ?? character }
        let folder = directory.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data("\(line)\u{1F}\(character)".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let joined = folder.appendingPathComponent("\(name).wav")
        if FileManager.default.fileExists(atPath: joined.path) { return joined.path }
        let partial = folder.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(6)).wav")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-i", line, "-i", character,
                                                                        "-filter_complex", "[0:a]aresample=24000[a];[1:a]aresample=24000[b];[a][b]concat=n=2:v=0:a=1[out]",
                                                                        "-map", "[out]", "-ac", "1", "-c:a", "pcm_s16le", partial.path])
        try FileOps.replaceItem(at: joined, with: partial)
        return joined.path
    }

    /// The empty style and the speed of 1 keep the keys of clips made by earlier versions.
    static func cacheKey(_ text: String, voice: String, engine: String) -> String {
        let material = [engine, voice, "", "1.000", text].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
