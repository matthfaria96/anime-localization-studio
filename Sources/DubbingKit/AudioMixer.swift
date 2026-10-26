import AVFoundation
import Foundation
import MediaKit

/// FFmpeg- and AVFoundation-based audio steps of the dub: trimming and fitting each clip to its
/// slot, laying the clips on one voice track, and mixing that track over the original audio.
public struct AudioMixer: Sendable {
    public let tools: ToolLocator
    static let sampleRate = 48_000.0

    public init(tools: ToolLocator) { self.tools = tools }

    public struct FittedClip: Sendable, Hashable {
        public let url: URL
        public let duration: Int
        /// Speed factor applied (1 = untouched).
        public let tempo: Double
        /// The clip is still longer than its slot after the maximum speed-up.
        public let overflows: Bool
    }

    /// Removes leading/trailing silence, converts to 48 kHz mono and, when the speech is longer
    /// than `slot`, speeds it up (pitch preserved by `atempo`) by at most `maxSpeedup`.
    public func fit(_ clip: URL, slot: Int, maxSpeedup: Double, to output: URL) async throws -> FittedClip {
        let ffmpeg = try tools.require(.ffmpeg)
        let trimmed = output.deletingPathExtension().appendingPathExtension("trim.wav")
        defer { try? FileManager.default.removeItem(at: trimmed) }
        let silence = "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.04"
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", clip.path,
                                                    "-af", "\(silence),areverse,\(silence),areverse",
                                                    "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", trimmed.path])
        // Silence-only output (nothing pronounceable) leaves an empty file with no duration.
        guard let length = try? await duration(of: trimmed), length > 0 else { throw SynthesisError.failed("a voz não gerou fala audível") }
        let needed = slot > 0 ? Double(length) / Double(slot) : 1
        let tempo = min(maxSpeedup, max(1, needed))
        if tempo > 1.001 {
            try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", trimmed.path,
                                                        "-af", String(format: "atempo=%.4f", tempo), "-c:a", "pcm_s16le", output.path])
        } else {
            try FileOps.replaceItem(at: output, with: trimmed)
        }
        let final = try await duration(of: output)
        return FittedClip(url: output, duration: final, tempo: tempo, overflows: slot > 0 && final > slot + 80)
    }

    public func duration(of url: URL) async throws -> Int {
        let ffprobe = try tools.require(.ffprobe)
        let result = try await ProcessRunner.runChecked(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                                                  "-of", "default=nw=1:nk=1", url.path])
        guard let seconds = Double(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MediaInspectionError.unreadable("Duração desconhecida de \(url.lastPathComponent).")
        }
        return Int(seconds * 1_000)
    }

    public struct Placement: Sendable, Hashable {
        public let id: Int
        public let url: URL
        public let start: Int
    }

    /// Writes one mono voice track: silence, then each clip at its start time. A clip that would
    /// overlap the previous one starts right after it instead (voices never talk over each
    /// other); the ids of those delayed clips are returned.
    public func assembleVoiceTrack(_ placements: [Placement], totalDuration: Int, to output: URL) throws -> [Int] {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        try? FileManager.default.removeItem(at: output)
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var cursor: AVAudioFramePosition = 0
        var delayed: [Int] = []
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        silence.frameLength = silence.frameCapacity
        func writeSilence(until target: AVAudioFramePosition) throws {
            while cursor < target {
                let frames = AVAudioFrameCount(min(Int64(silence.frameCapacity), target - cursor))
                silence.frameLength = frames
                try file.write(from: silence)
                cursor += AVAudioFramePosition(frames)
            }
        }
        for placement in placements.sorted(by: { $0.start < $1.start }) {
            let start = AVAudioFramePosition(Double(placement.start) / 1_000 * Self.sampleRate)
            if start < cursor { delayed.append(placement.id) } else { try writeSilence(until: start) }
            let clip = try AVAudioFile(forReading: placement.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard clip.length > 0, clip.processingFormat.sampleRate == Self.sampleRate, clip.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: clip.processingFormat, frameCapacity: AVAudioFrameCount(clip.length)) else { continue }
            try clip.read(into: buffer)
            try file.write(from: buffer)
            cursor += AVAudioFramePosition(buffer.frameLength)
        }
        try writeSilence(until: AVAudioFramePosition(Double(totalDuration) / 1_000 * Self.sampleRate))
        return delayed
    }

    /// Voice-over mix: the original track is lowered under the new voice (sidechain ducking),
    /// both are summed and the result is loudness-normalized (EBU R128, −16 LUFS) to AAC.
    public func mixVoiceOver(media: MediaInfo, audioTrack: MediaTrack, voice: URL, to output: URL,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let ffmpeg = try tools.require(.ffmpeg)
        guard let ordinal = media.ordinal(of: audioTrack) else { throw MediaInspectionError.unreadable("Faixa de áudio não encontrada.") }
        let graph = [
            "[0:a:\(ordinal)]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[bg]",
            "[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,asplit=2[vsc][vmix]",
            "[bg][vsc]sidechaincompress=threshold=0.02:ratio=9:attack=15:release=350[duck]",
            "[duck][vmix]amix=inputs=2:normalize=0:duration=first,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[out]"
        ].joined(separator: ";")
        let partial = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString.prefix(8)).partial.m4a")
        defer { try? FileManager.default.removeItem(at: partial) }
        let duration = media.durationMilliseconds
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-progress", "pipe:1", "-nostats",
                                                    "-i", media.url.path, "-i", voice.path, "-filter_complex", graph,
                                                    "-map", "[out]", "-c:a", "aac", "-b:a", "192k", partial.path]) { line in
            if let value = FFmpegProgressLine.fraction(line, durationMilliseconds: duration) { progress?(value) }
        }
        try FileOps.replaceItem(at: output, with: partial)
    }
}

/// Reads `out_time_us=` lines from FFmpeg's `-progress pipe:1`.
enum FFmpegProgressLine {
    static func fraction(_ line: String, durationMilliseconds: Int?) -> Double? {
        guard let duration = durationMilliseconds, duration > 0, line.hasPrefix("out_time_us="),
              let micros = Double(line.dropFirst("out_time_us=".count)) else { return nil }
        return min(1, max(0, micros / 1_000 / Double(duration)))
    }
}
