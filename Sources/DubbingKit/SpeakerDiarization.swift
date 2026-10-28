import FluidAudio
import Foundation

/// Who speaks when, on the Mac, with FluidAudio's offline pipeline (Apache-2.0): pyannote
/// Community-1 segmentation, WeSpeaker embeddings and PLDA/VBx clustering as Core ML models on
/// the Neural Engine. The models (CC-BY-4.0, about 22 MB) are downloaded from Hugging Face only
/// when the caller allows it.
public struct SpeakerDiarization: Sendable {
    public struct Turn: Sendable, Hashable {
        public let start: Int
        public let end: Int
        /// "Voz 1", "Voz 2"… numbered in order of first appearance: voices to be named by the
        /// person, never written into a subtitle as characters.
        public let speaker: String
    }

    public enum DiarizationError: Error, LocalizedError, Equatable {
        case modelsNotInstalled
        case nothingFound

        public var errorDescription: String? {
            switch self {
            case .modelsNotInstalled: String(localized: "Os modelos de identificação de falantes ainda não foram baixados.")
            case .nothingFound: String(localized: "Nenhuma voz foi encontrada no áudio.")
            }
        }
    }

    public static let downloadSize = String(localized: "cerca de 22 MB")
    public static let modelCredits = String(localized: "pyannote Community-1, WeSpeaker e BUT Speech@FIT (CC-BY-4.0), conversão Core ML da Fluid Inference")

    public let modelsDirectory: URL

    public init(modelsDirectory: URL) { self.modelsDirectory = modelsDirectory }

    public var modelsInstalled: Bool {
        let enumerator = FileManager.default.enumerator(at: modelsDirectory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Segmentation.mlmodelc" { return true }
        }
        return false
    }

    /// Speaker turns of a WAV file (any rate; FluidAudio converts it to 16 kHz mono).
    public func diarize(_ audio: URL, allowModelDownload: Bool, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Turn] {
        guard modelsInstalled || allowModelDownload else { throw DiarizationError.modelsNotInstalled }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: modelsDirectory)
        let result = try await manager.process(audio) { done, total in
            if total > 0 { progress?(Double(done) / Double(total)) }
        }
        var names: [String: String] = [:]
        let turns = result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { segment -> Turn in
                let name = names[segment.speakerId] ?? {
                    let label = String(localized: "Voz \(names.count + 1)")
                    names[segment.speakerId] = label
                    return label
                }()
                return Turn(start: Int(segment.startTimeSeconds * 1_000), end: Int(segment.endTimeSeconds * 1_000), speaker: name)
            }
        guard !turns.isEmpty else { throw DiarizationError.nothingFound }
        return turns
    }

    /// The speaker who talks the longest during each `(start, end)` interval, or `nil` when no
    /// turn overlaps it.
    public static func assign(_ turns: [Turn], to intervals: [(start: Int, end: Int)]) -> [String?] {
        intervals.map { interval in
            var overlap: [String: Int] = [:]
            for turn in turns where turn.end > interval.start && turn.start < interval.end {
                overlap[turn.speaker, default: 0] += min(turn.end, interval.end) - max(turn.start, interval.start)
            }
            return overlap.max { $0.value < $1.value }?.key
        }
    }
}
