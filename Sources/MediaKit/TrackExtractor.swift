import Foundation

/// Pulls single tracks out of a media file without altering them.
public struct TrackExtractor: Sendable {
    public let tools: ToolLocator

    public init(tools: ToolLocator) { self.tools = tools }

    /// Extracts a text subtitle track. Matroska files go through `mkvextract`, which rebuilds the
    /// ASS header (script info, styles) from the track's codec private data exactly as muxed;
    /// other containers, or Macs without MKVToolNix, use FFmpeg stream copy.
    public func extractSubtitle(_ track: MediaTrack, from info: MediaInfo, to destination: URL,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        if info.isMatroska, let mkvextract = tools.locate(.mkvextract) {
            try await ProcessRunner.runChecked(mkvextract, ["--gui-mode", info.url.path, "tracks", "\(track.id):\(partial.path)"],
                                               acceptedExitCodes: [0, 1]) { line in
                if let value = MKVMuxer.parseGUIProgress(line) { progress?(value) }
            }
        } else {
            let ffmpeg = try tools.require(.ffmpeg)
            guard let ordinal = info.ordinal(of: track) else { throw MediaInspectionError.unreadable("Faixa \(track.id) não encontrada.") }
            let format = track.textSubtitleExtension == "srt" ? "srt" : "ass"
            try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", info.url.path,
                                                        "-map", "0:s:\(ordinal)", "-c", "copy", "-f", format, partial.path])
        }
        guard FileManager.default.fileExists(atPath: partial.path) else {
            throw MediaInspectionError.unreadable("A extração não produziu um arquivo.")
        }
        try FileOps.replaceItem(at: destination, with: partial)
        progress?(1)
        return destination
    }

    /// Any track in its native format (fonts and other attachments are not tracks).
    public func extractRaw(_ track: MediaTrack, from info: MediaInfo, to destination: URL) async throws -> URL {
        let mkvextract = try tools.require(.mkvextract)
        try await ProcessRunner.runChecked(mkvextract, [info.url.path, "tracks", "\(track.id):\(destination.path)"], acceptedExitCodes: [0, 1])
        return destination
    }

    /// Decodes one audio track to WAV for analysis, transcription or separation.
    public func extractAudioWAV(_ track: MediaTrack, from info: MediaInfo, to destination: URL,
                                sampleRate: Int = 48_000, mono: Bool = false,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let ffmpeg = try tools.require(.ffmpeg)
        guard let ordinal = info.ordinal(of: track) else { throw MediaInspectionError.unreadable("Faixa de áudio \(track.id) não encontrada.") }
        var arguments = ["-nostdin", "-v", "error", "-y", "-progress", "pipe:1", "-nostats", "-i", info.url.path,
                         "-map", "0:a:\(ordinal)", "-vn", "-sn", "-c:a", "pcm_s16le", "-ar", "\(sampleRate)"]
        if mono { arguments += ["-ac", "1"] }
        arguments.append(destination.path)
        let duration = info.durationMilliseconds
        try await ProcessRunner.runChecked(ffmpeg, arguments) { line in
            if let value = FFmpegProgress.fraction(line, durationMilliseconds: duration) { progress?(value) }
        }
        return destination
    }
}

enum FFmpegProgress {
    /// Reads `out_time_us=` lines from `-progress pipe:1`.
    static func fraction(_ line: String, durationMilliseconds: Int?) -> Double? {
        guard let duration = durationMilliseconds, duration > 0,
              line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) else { return nil }
        return min(1, max(0, micros / 1_000 / Double(duration)))
    }
}

public enum FileOps {
    /// Moves `source` onto `destination`, replacing it if present (same volume: atomic rename).
    public static func replaceItem(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    /// `Name.mkv` → `Name (2).mkv` … until the name is free. Existing files are never overwritten.
    public static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Free space on the volume, or `nil` when no source can tell.
    ///
    /// The "important usage" figure is 0 on exFAT, FAT32, NTFS and many network volumes even
    /// when they have terabytes free, so the largest of the three sources wins.
    public static func availableCapacity(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        var info = statfs()
        let fileSystem = statfs(directory.path, &info) == 0 ? Int64(info.f_bavail) * Int64(info.f_bsize) : nil
        return bestCapacity(importantUsage: values?.volumeAvailableCapacityForImportantUsage,
                            available: values?.volumeAvailableCapacity.map(Int64.init), fileSystem: fileSystem)
    }

    static func bestCapacity(importantUsage: Int64?, available: Int64?, fileSystem: Int64?) -> Int64? {
        let known = [importantUsage, available, fileSystem].compactMap { $0 }.filter { $0 > 0 }
        return known.max()
    }
}
