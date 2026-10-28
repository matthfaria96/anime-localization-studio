import Foundation
import MediaKit

/// Removing audio or subtitle tracks (and, when asked, fonts only they used) from the video,
/// into a new file or the file itself, verified like every other write.
extension EpisodeWorkflow {
    public func removeTracks(_ project: StudioProject, trackIDs: Set<Int>, attachmentIDs: Set<Int> = [], replaceOriginal: Bool,
                             progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, URL, VerificationReport) {
        var project = project
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let removable = info.tracks.filter { trackIDs.contains($0.id) && ($0.kind == .audio || $0.kind == .subtitles) }
        guard !removable.isEmpty else { throw MuxError.missingInput("faixa") }
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: String(localized: "editado")), newTracks: [],
                           clearOtherDefaults: false)
        plan.excludedTrackIDs = Set(removable.map(\.id))
        plan.excludedAttachmentIDs = attachmentIDs
        plan.replaceSource = replaceOriginal
        let (url, report) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: value, message: value < 0.9 ? String(localized: "Gravando o MKV…") : String(localized: "Verificando integridade…")))
        }
        if replaceOriginal, let output = report.outputInfo {
            Self.remapTrackIDs(&project, from: info, removed: plan.excludedTrackIDs, to: output)
            project.mediaFingerprint = Self.fingerprint(of: url)
        }
        project.lastOutputPath = url.path
        project.lastVerification = report
        try store.save(project)
        return (project, url, report)
    }

    /// After a rewrite, mkvmerge numbers the tracks again: the project's references (the
    /// subtitle being edited, the one beside it, the dub's audio and text…) follow their tracks,
    /// and references to removed tracks are cleared.
    public static func remapTrackIDs(_ project: inout StudioProject, from old: MediaInfo, removed: Set<Int>, to new: MediaInfo) {
        var map: [Int: Int] = [:]
        for kind in MediaTrack.Kind.allCases {
            var remaining = new.tracks(kind)
            for track in old.tracks(kind) where !removed.contains(track.id) {
                guard let index = remaining.firstIndex(where: { IntegrityVerifier.sameTrack(track, $0) }) else { continue }
                map[track.id] = remaining.remove(at: index).id
            }
        }
        func follow(_ id: Int?) -> Int? { id.flatMap { map[$0] } }
        let sourceWasRemoved = project.sourceTrackID.map(removed.contains) ?? false
        project.sourceTrackID = follow(project.sourceTrackID)
        project.sourceFileTrackID = sourceWasRemoved ? nil : follow(project.sourceFileTrackID)
        project.referenceTrackID = follow(project.referenceTrackID)
        project.dubAudioTrackID = follow(project.dubAudioTrackID)
        project.dubTextTrackID = follow(project.dubTextTrackID)
        if let speakers = project.autoSpeakers {
            project.autoSpeakers = Dictionary(uniqueKeysWithValues: speakers.compactMap { key, value -> (String, [Int: String])? in
                guard key.hasPrefix("track-"), let id = Int(key.dropFirst(6)) else { return (key, value) }
                return map[id].map { ("track-\($0)", value) }
            })
        }
        if let pending = project.remoteDub {
            project.remoteDub = map[pending.audioTrackID].map { var moved = pending; moved.audioTrackID = $0; return moved }
        }
    }
}
