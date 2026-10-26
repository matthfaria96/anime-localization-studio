import CryptoKit
import Foundation

/// AVFoundation cannot open Matroska. For playback inside the app, the video stream is copied
/// into a cached MP4 next to one audio track (converted to AAC). Video is only re-encoded, to a
/// small H.264 preview, when its codec cannot be played by AVFoundation (H.264 High 10, VP9,
/// MPEG-2…). The proxy is a preview only: exports always use the original file.
public struct PreviewProxy: Sendable {
    public let tools: ToolLocator
    public let cacheDirectory: URL

    public init(tools: ToolLocator, cacheDirectory: URL) {
        self.tools = tools
        self.cacheDirectory = cacheDirectory
    }

    public static func canPlayDirectly(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    public enum Mode: String, Sendable { case copiedVideo, previewEncode }

    public func cachedURL(for info: MediaInfo, audioTrack: MediaTrack?) -> URL {
        let modified = (try? info.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(info.url.path)|\(info.fileSize)|\(modified)|\(audioTrack?.id ?? -1)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(digest).mp4")
    }

    public func make(for info: MediaInfo, audioTrack: MediaTrack?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (URL, Mode) {
        let output = cachedURL(for: info, audioTrack: audioTrack)
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let ffmpeg = try tools.require(.ffmpeg)
        let mode = try await videoMode(for: info)
        if fm.fileExists(atPath: output.path) { return (output, mode) }

        let partial = output.deletingPathExtension().appendingPathExtension("\(UUID().uuidString.prefix(8)).partial.mp4")
        var args = ["-nostdin", "-v", "error", "-y", "-progress", "pipe:1", "-nostats", "-i", info.url.path, "-map", "0:v:0"]
        if let audio = audioTrack, let ordinal = info.ordinal(of: audio) {
            args += ["-map", "0:a:\(ordinal)", "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }
        switch mode {
        case .copiedVideo:
            args += ["-c:v", "copy"]
            if info.tracks(.video).first?.codecID.uppercased().contains("HEVC") == true { args += ["-tag:v", "hvc1"] }
        case .previewEncode:
            args += ["-c:v", "h264_videotoolbox", "-b:v", "5M", "-vf", "scale=-2:'min(720,ih)'", "-pix_fmt", "yuv420p"]
        }
        args += ["-sn", "-dn", "-map_chapters", "-1", "-movflags", "+faststart", partial.path]
        let duration = info.durationMilliseconds
        do {
            try await ProcessRunner.runChecked(ffmpeg, args) { line in
                if let value = FFmpegProgress.fraction(line, durationMilliseconds: duration) { progress?(value) }
            }
            try FileOps.replaceItem(at: output, with: partial)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return (output, mode)
    }

    /// Codecs AVFoundation decodes on Apple silicon, checked with ffprobe for the H.264 profile
    /// (10-bit H.264, common in older fansubs, is not supported by VideoToolbox).
    func videoMode(for info: MediaInfo) async throws -> Mode {
        guard let ffprobe = tools.locate(.ffprobe) else { return .previewEncode }
        let result = try await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                          "stream=codec_name,profile,pix_fmt", "-of", "default=nw=1", info.url.path])
        let text = result.stdoutText.lowercased()
        let codec = text.firstLine(prefix: "codec_name=") ?? ""
        let profile = text.firstLine(prefix: "profile=") ?? ""
        let pixel = text.firstLine(prefix: "pix_fmt=") ?? ""
        switch codec {
        case "h264": return profile.contains("10") || pixel.contains("10") || pixel.contains("422") || pixel.contains("444") ? .previewEncode : .copiedVideo
        case "hevc", "av1", "prores", "mpeg4": return .copiedVideo
        default: return .previewEncode
        }
    }

    /// Removes cached previews (they can be rebuilt at any time).
    public func clearCache() throws {
        if FileManager.default.fileExists(atPath: cacheDirectory.path) { try FileManager.default.removeItem(at: cacheDirectory) }
    }
}

extension String {
    func firstLine(prefix: String) -> String? {
        split(whereSeparator: \.isNewline).first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
