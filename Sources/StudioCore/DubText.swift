import DubbingKit
import Foundation
import MediaKit
import SubtitleKit

/// What a dub speaks: the app's translation, or a subtitle track already in the video (for
/// example a Portuguese track), in that subtitle's language.
public struct DubText: Sendable {
    public let document: SubtitleDocument
    /// `translation` or `track-<id>`, the key of the speakers found for it.
    public let key: String
    public let language: String
    public let file: URL
    /// The subtitle already is in the video (nothing to add besides the audio).
    public let isVideoTrack: Bool
}

extension EpisodeWorkflow {
    public func dubText(_ project: StudioProject, trackID: Int?, info: MediaInfo? = nil) async throws -> DubText {
        guard let trackID else {
            guard let url = store.translationURL(for: project, language: settings.targetLanguage),
                  let document = try? SubtitleDocument.load(url) else { throw WorkflowError.notTranslated }
            return DubText(document: document.withSideSpeakers(project.lineSpeakers ?? [:]), key: "translation",
                           language: settings.targetLanguage, file: url, isVideoTrack: false)
        }
        let info = if let info { info } else { try await MediaInspector(tools: tools).inspect(project.mediaURL) }
        guard let track = info.tracks.first(where: { $0.id == trackID }), let ext = track.textSubtitleExtension else { throw WorkflowError.noTextSubtitle }
        let url = store.directory(for: project.id).appendingPathComponent("speak-\(trackID).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = try await TrackExtractor(tools: tools).extractSubtitle(track, from: info, to: url)
        }
        return DubText(document: try SubtitleDocument.load(url), key: "track-\(trackID)", language: Self.language(of: track),
                       file: url, isVideoTrack: true)
    }

    /// The lines to speak, with the speakers found from the audio filled in where the subtitle
    /// does not say who speaks.
    public func spokenSegments(_ text: DubText, project: StudioProject) -> [DubSegment] {
        DubbingPlan.segments(from: text.document.withSideSpeakers(project.autoSpeakers?[text.key] ?? [:]))
    }

    /// A track's language as BCP 47 (`por` → `pt`, `pt-BR` stays).
    public static func language(of track: MediaTrack) -> String {
        if let ietf = track.languageIETF, !ietf.isEmpty, ietf != "und" { return ietf }
        let table = ["por": "pt-BR", "eng": "en", "jpn": "ja", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
                     "ita": "it", "chi": "zh", "zho": "zh", "kor": "ko", "rus": "ru", "ara": "ar"]
        return table[track.language] ?? track.language
    }
}
