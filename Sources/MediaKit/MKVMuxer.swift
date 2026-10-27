import Foundation

/// A file to add to the container as a new track.
public struct NewTrack: Sendable, Hashable, Codable {
    public var file: URL
    public var kind: MediaTrack.Kind
    /// BCP 47 tag written as the track language, e.g. `pt-BR`.
    public var language: String
    public var name: String
    public var isDefault: Bool
    public var isForced: Bool

    public init(file: URL, kind: MediaTrack.Kind, language: String = "pt-BR", name: String, isDefault: Bool = true, isForced: Bool = false) {
        self.file = file
        self.kind = kind
        self.language = language
        self.name = name
        self.isDefault = isDefault
        self.isForced = isForced
    }
}

public struct MuxPlan: Sendable, Hashable, Codable {
    public var source: MediaInfo
    public var output: URL
    public var newTracks: [NewTrack]
    /// A new default track clears the default flag of the existing tracks of the same kind,
    /// so players pick the new one.
    public var clearOtherDefaults: Bool
    /// Places each new track first among the tracks of its kind.
    public var placeNewTracksFirst: Bool
    /// After the new file is verified, it takes the original's place and the original goes to
    /// the Trash (recoverable). `output` is ignored.
    public var replaceSource: Bool = false
    /// Tracks of the source left out of the result (an edited subtitle replaces its old version).
    public var excludedTrackIDs: Set<Int> = []
    /// Attachments of the source left out (fonts no remaining subtitle uses).
    public var excludedAttachmentIDs: Set<Int> = []
    /// Files attached to the result (fonts the subtitle needs). One already attached under the
    /// same name is not attached twice.
    public var attachments: [URL] = []

    /// Attachments that are really added (not already in the source).
    public var newAttachments: [URL] {
        let existing = Set(source.attachments.map { $0.fileName.lowercased() })
        var seen = Set<String>()
        return attachments.filter { url in
            let name = url.lastPathComponent.lowercased()
            return !existing.contains(name) && seen.insert(name).inserted
        }
    }

    /// Source tracks that stay in the result.
    public var keptTracks: [MediaTrack] { source.tracks.filter { !excludedTrackIDs.contains($0.id) } }

    public init(source: MediaInfo, output: URL, newTracks: [NewTrack], clearOtherDefaults: Bool = true, placeNewTracksFirst: Bool = false) {
        self.source = source
        self.output = output
        self.newTracks = newTracks
        self.clearOtherDefaults = clearOtherDefaults
        self.placeNewTracksFirst = placeNewTracksFirst
    }

    /// `Episode 01.mkv` → `Episode 01 [PT-BR].mkv` next to the source.
    /// A name that already ends with the suffix keeps it once (“[PT-BR DUB] (2)”, not “[PT-BR DUB] [PT-BR DUB]”).
    public static func defaultOutputURL(for source: URL, suffix: String = "PT-BR") -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let name = base.hasSuffix("[\(suffix)]") ? base : "\(base) [\(suffix)]"
        return source.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("mkv")
    }
}

public enum MuxError: Error, LocalizedError, Equatable {
    case insufficientSpace(needed: Int64, available: Int64)
    case outputIsSource
    case missingInput(String)
    case verificationFailed([String])

    public var errorDescription: String? {
        switch self {
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Espaço insuficiente no disco de destino: são necessários \(f.string(fromByteCount: needed)) e há \(f.string(fromByteCount: available))."
        case .outputIsSource: return "O arquivo de saída não pode ser o próprio original."
        case .missingInput(let name): return "O arquivo “\(name)” a incorporar não existe."
        case .verificationFailed(let problems): return "O arquivo gerado não passou na verificação: " + problems.joined(separator: " ")
        }
    }
}

/// Builds a new Matroska file with `mkvmerge`: every original track, attachment (fonts),
/// chapter and tag is copied bit for bit (no re-encoding), plus the new tracks.
/// The original file is only read. The result is written to a hidden partial file, verified,
/// and only then renamed to its final name, which never replaces an existing file.
public struct MKVMuxer: Sendable {
    public let tools: ToolLocator

    public init(tools: ToolLocator) { self.tools = tools }

    public func mux(_ plan: MuxPlan, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (url: URL, report: VerificationReport) {
        let fm = FileManager.default
        let mkvmerge = try tools.require(.mkvmerge)
        guard plan.replaceSource || plan.output.standardizedFileURL != plan.source.url.standardizedFileURL else { throw MuxError.outputIsSource }
        for track in plan.newTracks where !fm.fileExists(atPath: track.file.path) {
            throw MuxError.missingInput(track.file.lastPathComponent)
        }
        let directory = (plan.replaceSource ? plan.source.url : plan.output).deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let addedBytes = plan.newTracks.reduce(Int64(0)) { total, track in
            total + Int64((try? track.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let needed = plan.source.fileSize + addedBytes + 64 * 1_024 * 1_024
        if let available = FileOps.availableCapacity(at: directory), available < needed {
            throw MuxError.insufficientSpace(needed: needed, available: available)
        }

        // Unique per run: two runs for the same episode never touch each other's partial file.
        let partial = directory.appendingPathComponent(".\((plan.replaceSource ? plan.source.url : plan.output).deletingPathExtension().lastPathComponent).\(UUID().uuidString.prefix(8)).partial.mkv")
        do {
            // mkvmerge exit codes: 0 success, 1 success with warnings, 2 error.
            try await ProcessRunner.runChecked(mkvmerge, Self.arguments(for: plan, output: partial), acceptedExitCodes: [0, 1]) { line in
                if let value = Self.parseGUIProgress(line) { progress?(value * 0.9) }
            }
            var report = try await IntegrityVerifier(tools: tools).verifyMux(plan: plan, output: partial)
            guard report.passed else { throw MuxError.verificationFailed(report.failures) }
            let final: URL
            if plan.replaceSource {
                final = plan.source.url
                try FileOps.trash(plan.source.url)
                try fm.moveItem(at: partial, to: final)
            } else {
                final = FileOps.uniqueURL(for: plan.output)
                try fm.moveItem(at: partial, to: final)
            }
            report.outputInfo?.url = final
            progress?(1)
            return (final, report)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    static func arguments(for plan: MuxPlan, output: URL) -> [String] {
        var args = ["--gui-mode", "--output", output.path]
        let newDefaultKinds = Set(plan.newTracks.filter(\.isDefault).map(\.kind))
        if plan.clearOtherDefaults {
            for track in plan.keptTracks where newDefaultKinds.contains(track.kind) && track.isDefault {
                args += ["--default-track-flag", "\(track.id):0"]
            }
        }
        let excludedSubtitles = plan.source.tracks(.subtitles).filter { plan.excludedTrackIDs.contains($0.id) }.map { String($0.id) }
        if !excludedSubtitles.isEmpty { args += ["--subtitle-tracks", "!" + excludedSubtitles.joined(separator: ",")] }
        let excludedAudio = plan.source.tracks(.audio).filter { plan.excludedTrackIDs.contains($0.id) }.map { String($0.id) }
        if !excludedAudio.isEmpty { args += ["--audio-tracks", "!" + excludedAudio.joined(separator: ",")] }
        let excludedAttachments = plan.source.attachments.filter { plan.excludedAttachmentIDs.contains($0.id) }.map { String($0.id) }
        if !excludedAttachments.isEmpty { args += ["--attachments", "!" + excludedAttachments.joined(separator: ",")] }
        args.append(plan.source.url.path)
        for track in plan.newTracks {
            args += ["--language", "0:\(track.language)",
                     "--track-name", "0:\(track.name)",
                     "--default-track-flag", "0:\(track.isDefault ? 1 : 0)",
                     "--forced-display-flag", "0:\(track.isForced ? 1 : 0)"]
            if track.kind == .subtitles, ["srt", "ass", "ssa"].contains(track.file.pathExtension.lowercased()) {
                args += ["--sub-charset", "0:UTF-8"]
            }
            // Added files contribute one track only: never their chapters, tags or attachments.
            args += ["--no-chapters", "--no-global-tags", "--no-attachments"]
            args.append(track.file.path)
        }
        for file in plan.newAttachments { args += ["--attach-file", file.path] }
        args += ["--track-order", trackOrder(for: plan)]
        return args
    }

    /// `0:0,1:0,0:1,0:2` — file:track pairs grouped as video, audio, subtitles, then the rest.
    static func trackOrder(for plan: MuxPlan) -> String {
        var order: [String] = []
        for kind in [MediaTrack.Kind.video, .audio, .subtitles, .other] {
            let existing = plan.source.tracks(kind).filter { !plan.excludedTrackIDs.contains($0.id) }.map { "0:\($0.id)" }
            let added = plan.newTracks.enumerated().filter { $0.element.kind == kind }.map { "\($0.offset + 1):0" }
            order += plan.placeNewTracksFirst ? added + existing : existing + added
        }
        return order.joined(separator: ",")
    }

    /// `#GUI#progress 42%` → 0.42.
    static func parseGUIProgress(_ line: String) -> Double? {
        guard line.hasPrefix("#GUI#progress "), let value = Double(line.dropFirst("#GUI#progress ".count).dropLast()) else { return nil }
        return value / 100
    }
}
