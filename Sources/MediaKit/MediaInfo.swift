import Foundation

public struct MediaTrack: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case video, audio, subtitles, other

        public var label: String {
            switch self {
            case .video: "Vídeo"
            case .audio: "Áudio"
            case .subtitles: "Legenda"
            case .other: "Outro"
            }
        }
    }

    /// The track id `mkvmerge`/`mkvextract` use (`0:`, `1:`…), or the FFmpeg stream index.
    public var id: Int
    public var kind: Kind
    /// Human-readable codec, e.g. `AVC/H.264/MPEG-4p10` or `SubStationAlpha`.
    public var codec: String
    /// Matroska codec id (`V_MPEG4/ISO/AVC`, `S_TEXT/ASS`) or FFmpeg codec name.
    public var codecID: String
    /// ISO 639-2 language (`jpn`, `eng`, `und`).
    public var language: String
    /// BCP 47 language (`ja`, `pt-BR`), when the container has one.
    public var languageIETF: String?
    public var name: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var width: Int?
    public var height: Int?
    public var channels: Int?
    public var sampleRate: Int?

    public init(id: Int, kind: Kind, codec: String, codecID: String, language: String = "und", languageIETF: String? = nil,
                name: String? = nil, isDefault: Bool = false, isForced: Bool = false, width: Int? = nil, height: Int? = nil,
                channels: Int? = nil, sampleRate: Int? = nil) {
        self.id = id
        self.kind = kind
        self.codec = codec
        self.codecID = codecID
        self.language = language
        self.languageIETF = languageIETF
        self.name = name
        self.isDefault = isDefault
        self.isForced = isForced
        self.width = width
        self.height = height
        self.channels = channels
        self.sampleRate = sampleRate
    }

    /// The best language tag to show: the IETF tag when present, else the ISO 639-2 code.
    public var displayLanguage: String {
        if let ietf = languageIETF, !ietf.isEmpty, ietf != "und" { return ietf }
        return language
    }

    /// Text subtitle formats the editor can open (`S_TEXT/ASS`, `S_TEXT/SSA`, `S_TEXT/UTF8`).
    public var textSubtitleExtension: String? {
        switch codecID.uppercased() {
        case "S_TEXT/ASS", "ASS": "ass"
        case "S_TEXT/SSA", "SSA": "ssa"
        case "S_TEXT/UTF8", "SUBRIP", "SRT": "srt"
        default: nil
        }
    }

    /// Image-based subtitles (PGS, VobSub) cannot be translated without OCR.
    public var isBitmapSubtitle: Bool {
        kind == .subtitles && ["S_HDMV/PGS", "S_VOBSUB", "HDMV_PGS_SUBTITLE", "DVD_SUBTITLE"].contains(codecID.uppercased())
    }
}

public struct MediaAttachment: Sendable, Hashable, Codable, Identifiable {
    public var id: Int
    public var fileName: String
    public var mimeType: String
    public var size: Int64

    public var isFont: Bool {
        mimeType.contains("font") || ["ttf", "otf", "ttc"].contains((fileName as NSString).pathExtension.lowercased())
    }
}

public struct MediaInfo: Sendable, Hashable, Codable {
    public var url: URL
    public var container: String
    public var title: String?
    public var durationMilliseconds: Int?
    public var fileSize: Int64
    public var tracks: [MediaTrack]
    public var attachments: [MediaAttachment]
    public var chapterCount: Int
    public var warnings: [String]

    public init(url: URL, container: String, title: String? = nil, durationMilliseconds: Int? = nil, fileSize: Int64 = 0,
                tracks: [MediaTrack] = [], attachments: [MediaAttachment] = [], chapterCount: Int = 0, warnings: [String] = []) {
        self.url = url
        self.container = container
        self.title = title
        self.durationMilliseconds = durationMilliseconds
        self.fileSize = fileSize
        self.tracks = tracks
        self.attachments = attachments
        self.chapterCount = chapterCount
        self.warnings = warnings
    }

    public var isMatroska: Bool { container.lowercased().contains("matroska") || container.lowercased().contains("webm") }

    public func tracks(_ kind: MediaTrack.Kind) -> [MediaTrack] { tracks.filter { $0.kind == kind } }

    /// Position of a track among the tracks of its kind (FFmpeg's `0:a:N` numbering).
    public func ordinal(of track: MediaTrack) -> Int? {
        tracks(track.kind).firstIndex { $0.id == track.id }
    }

    /// The subtitle track most likely to be the full dialogue in `preferredLanguages`
    /// (ISO 639-2 or BCP 47), preferring ASS over SRT and avoiding “Signs/Songs” or forced tracks.
    public func bestSourceSubtitle(preferredLanguages: [String] = ["eng", "en", "jpn", "ja"]) -> MediaTrack? {
        let candidates = tracks(.subtitles).filter { $0.textSubtitleExtension != nil }
        func score(_ track: MediaTrack) -> Int {
            var score = 0
            let languages = [track.language.lowercased(), track.languageIETF?.lowercased() ?? ""]
            if let rank = preferredLanguages.firstIndex(where: { languages.contains($0.lowercased()) }) {
                score += 100 - rank * 10
            }
            let name = (track.name ?? "").lowercased()
            if ["sign", "song", "forced", "karaoke", "commentary", "comentário"].contains(where: name.contains) { score -= 60 }
            if ["full", "dialogue", "diálogo", "completa"].contains(where: name.contains) { score += 20 }
            if track.isForced { score -= 40 }
            if track.textSubtitleExtension == "ass" || track.textSubtitleExtension == "ssa" { score += 15 }
            if track.isDefault { score += 5 }
            if languages.contains("por") || languages.contains(where: { $0.hasPrefix("pt") }) { score -= 200 }
            return score
        }
        return candidates.max { score($0) < score($1) }
    }
}
