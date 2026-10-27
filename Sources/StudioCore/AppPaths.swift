import Foundation

/// Where the app keeps its data. Nothing is ever written next to the user's media except the
/// new files they ask for (muxed MKVs, exported subtitles).
public struct AppPaths: Sendable {
    public let root: URL
    public let caches: URL

    public init(root: URL? = nil, caches: URL? = nil) {
        let fm = FileManager.default
        self.root = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anime Localization Studio", isDirectory: true)
        self.caches = caches ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anime Localization Studio", isDirectory: true)
    }

    public var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    public var series: URL { root.appendingPathComponent("Series", isDirectory: true) }
    public var jobs: URL { root.appendingPathComponent("jobs.json") }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var library: URL { root.appendingPathComponent("library.json") }
    /// Downloaded on-device models (speaker diarization).
    public var diarizationModels: URL { root.appendingPathComponent("Models/Diarization", isDirectory: true) }
    /// On-device voice cloning model (Chatterbox Multilingual).
    public var voiceModels: URL { root.appendingPathComponent("Models/Chatterbox", isDirectory: true) }
    /// The earlier voice model (PocketTTS), only to be measured and cleared.
    public var legacyVoiceModels: URL { root.appendingPathComponent("Models/PocketTTS", isDirectory: true) }
    /// Chatterbox's speech tokenizer, which its loader keeps in the user's Caches.
    public var voiceTokenizer: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chatterbox-s3-tokenizer", isDirectory: true)
    }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var previews: URL { caches.appendingPathComponent("Previews", isDirectory: true) }
    public var scratch: URL { caches.appendingPathComponent("Work", isDirectory: true) }
}

enum JSONFile {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    /// Atomic write: a crash mid-save leaves the previous version intact.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
