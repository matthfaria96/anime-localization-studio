import AVFoundation
import Foundation
import MediaKit

/// Samples of each character's original voice, taken from the episode itself: the dialogue is
/// isolated from music and effects, and the longest lines of the speaker are joined into a
/// clip of about 12 s. Used to recognize who is who and to clone the voice on the Mac.
public struct OriginalVoices: Sendable {
    public let tools: ToolLocator
    public let workDirectory: URL

    public init(tools: ToolLocator, workDirectory: URL) {
        self.tools = tools
        self.workDirectory = workDirectory
    }

    public struct Sample: Sendable, Hashable {
        public let speaker: String
        public let url: URL
        /// What is said in the sample, in the original language (reference text for cloning).
        public let text: String
        /// Median voice pitch in Hz, or `nil` when it could not be measured.
        public let pitch: Double?
    }

    /// Lines of the original: (id, start, end, speaker, original text).
    public typealias Line = (id: Int, start: Int, end: Int, speaker: String, text: String)

    public func samples(for lines: [Line], media: MediaInfo, audioTrack: MediaTrack, seconds: Double = 12,
                        progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> [Sample] {
        let ffmpeg = try tools.require(.ffmpeg)
        let voices = workDirectory.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        let dialogue = try await isolatedDialogue(media: media, audioTrack: audioTrack, progress: progress)
        let speakers = Array(Set(lines.map(\.speaker))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var samples: [Sample] = []
        for (n, speaker) in speakers.enumerated() {
            progress?(0.6 + 0.4 * Double(n) / Double(max(1, speakers.count)), "Separando a voz de \(speaker)…")
            var chosen: [Line] = []
            var total = 0
            for line in lines.filter({ $0.speaker == speaker }).sorted(by: { ($0.end - $0.start) > ($1.end - $1.start) }) {
                guard total < Int(seconds * 1_000) else { break }
                chosen.append(line)
                total += line.end - line.start
            }
            chosen.sort { $0.start < $1.start }
            guard !chosen.isEmpty else { continue }
            let output = voices.appendingPathComponent("\(Self.fileName(speaker)).wav")
            let filter = chosen.enumerated().map { i, line in
                "[0:a]atrim=start=\(Double(line.start) / 1_000):end=\(Double(line.end) / 1_000),asetpts=PTS-STARTPTS[s\(i)]"
            }.joined(separator: ";") + ";" + chosen.indices.map { "[s\($0)]" }.joined() + "concat=n=\(chosen.count):v=0:a=1,aresample=24000[out]"
            try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", dialogue.path, "-filter_complex", filter,
                                                        "-map", "[out]", "-ac", "1", "-c:a", "pcm_s16le", output.path])
            samples.append(Sample(speaker: speaker, url: output, text: chosen.map(\.text).joined(separator: " "), pitch: Self.medianPitch(of: output)))
        }
        return samples
    }

    /// The original audio of each line, voices only, to clone the voice and the emotion of that
    /// very line. Lines shorter than `minimumMilliseconds` are left out (too little to clone from).
    public func lineClips(for lines: [Line], media: MediaInfo, audioTrack: MediaTrack, minimumMilliseconds: Int = 1_500,
                          progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> [Int: URL] {
        let ffmpeg = try tools.require(.ffmpeg)
        let folder = workDirectory.appendingPathComponent("lines-\(audioTrack.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dialogue = try await isolatedDialogue(media: media, audioTrack: audioTrack, progress: progress)
        let usable = lines.filter { $0.end - $0.start >= minimumMilliseconds }
        var clips: [Int: URL] = [:]
        for (n, line) in usable.enumerated() {
            try Task.checkCancellation()
            progress?(0.6 + 0.4 * Double(n) / Double(max(1, usable.count)), "Separando a voz de cada fala (\(n + 1) de \(usable.count))…")
            let clip = folder.appendingPathComponent("\(line.start)-\(line.end).wav")
            if !FileManager.default.fileExists(atPath: clip.path) {
                try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", dialogue.path,
                                                            "-ss", String(format: "%.3f", Double(line.start) / 1_000),
                                                            "-to", String(format: "%.3f", Double(line.end) / 1_000),
                                                            "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", clip.path])
            }
            clips[line.id] = clip
        }
        return clips
    }

    /// The original audio with only the voices (cached per track).
    func isolatedDialogue(media: MediaInfo, audioTrack: MediaTrack, progress: (@Sendable (Double, String) -> Void)?) async throws -> URL {
        let dialogue = workDirectory.appendingPathComponent("dialogue-\(audioTrack.id).wav")
        if FileManager.default.fileExists(atPath: dialogue.path) { return dialogue }
        let original = workDirectory.appendingPathComponent("original-\(audioTrack.id).wav")
        defer { try? FileManager.default.removeItem(at: original) }
        progress?(0.05, "Extraindo o áudio original…")
        _ = try await TrackExtractor(tools: tools).extractAudioWAV(audioTrack, from: media, to: original)
        let background = workDirectory.appendingPathComponent("background-\(audioTrack.id).wav")
        let partial = workDirectory.appendingPathComponent(".dialogue-\(UUID().uuidString.prefix(6)).wav")
        try await VoiceSeparator(tools: tools).separate(original, voice: partial, background: background) { value in
            progress?(0.1 + value * 0.5, "Isolando as vozes da música e dos efeitos…")
        }
        try FileOps.replaceItem(at: dialogue, with: partial)
        return dialogue
    }

    static func fileName(_ speaker: String) -> String {
        let allowed = speaker.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        return allowed.isEmpty ? "voz" : allowed
    }

    /// Median fundamental frequency by autocorrelation over voiced 40 ms frames (70–400 Hz).
    static func medianPitch(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else { return nil }
        let rate = file.processingFormat.sampleRate
        let count = Int(buffer.frameLength)
        let frame = Int(rate * 0.04)
        let minLag = Int(rate / 400), maxLag = Int(rate / 70)
        var pitches: [Double] = []
        var start = 0
        while start + frame + maxLag < count {
            var energy: Float = 0
            for i in 0..<frame { energy += samples[start + i] * samples[start + i] }
            if energy / Float(frame) > 1e-4 {
                var best: Float = 0, bestLag = 0
                for lag in minLag...maxLag {
                    var sum: Float = 0
                    for i in 0..<frame { sum += samples[start + i] * samples[start + i + lag] }
                    if sum > best { best = sum; bestLag = lag }
                }
                if best / energy > 0.5, bestLag > 0 { pitches.append(rate / Double(bestLag)) }
            }
            start += frame
        }
        guard !pitches.isEmpty else { return nil }
        return pitches.sorted()[pitches.count / 2]
    }
}
