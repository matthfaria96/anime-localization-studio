import Foundation

/// Changes which audio and subtitle tracks are the default ones, with `mkvpropedit`: the
/// header is edited in place in a fraction of a second, without rewriting the file.
public struct TrackFlagEditor: Sendable {
    public let tools: ToolLocator

    public init(tools: ToolLocator) { self.tools = tools }

    public struct Defaults: Sendable, Hashable {
        public var audioTrackID: Int?
        public var subtitleTrackID: Int?
        public init(audioTrackID: Int?, subtitleTrackID: Int?) {
            self.audioTrackID = audioTrackID
            self.subtitleTrackID = subtitleTrackID
        }
    }

    /// Arguments for mkvpropedit. `track:N` counts tracks from 1 in file order, which is the
    /// mkvmerge id + 1. A kind whose choice is `nil` is left untouched; choosing a subtitle id
    /// of -1 turns every subtitle off by default.
    static func arguments(for info: MediaInfo, defaults: Defaults) -> [String] {
        var args: [String] = []
        func set(_ kind: MediaTrack.Kind, _ chosen: Int?) {
            guard let chosen else { return }
            for track in info.tracks(kind) {
                args += ["--edit", "track:\(track.id + 1)", "--set", "flag-default=\(track.id == chosen ? 1 : 0)"]
            }
        }
        set(.audio, defaults.audioTrackID)
        set(.subtitles, defaults.subtitleTrackID)
        return args
    }

    /// Edits `info.url` itself, or a copy at `copyTo` (the original is then untouched).
    @discardableResult
    public func apply(_ defaults: Defaults, to info: MediaInfo, copyTo: URL? = nil) async throws -> URL {
        let tool = try tools.require(.mkvpropedit)
        guard info.isMatroska else { throw MediaInspectionError.unreadable(String(localized: "Só arquivos MKV podem ter as faixas padrão alteradas sem regravar.")) }
        let args = Self.arguments(for: info, defaults: defaults)
        guard !args.isEmpty else { return info.url }
        var target = info.url
        if let copyTo {
            target = FileOps.uniqueURL(for: copyTo)
            try FileManager.default.copyItem(at: info.url, to: target)
        }
        do {
            try await ProcessRunner.runChecked(tool, [target.path] + args, acceptedExitCodes: [0, 1])
        } catch {
            if copyTo != nil { try? FileManager.default.removeItem(at: target) }
            throw error
        }
        return target
    }
}
