import Foundation

public enum MediaInspectionError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): String(localized: "O arquivo não pôde ser analisado. Pode estar corrompido ou em um formato não suportado. \(detail)")
        case .notFound: String(localized: "O arquivo não existe mais nesse local.")
        }
    }
}

/// Reads tracks, languages, flags, attachments and chapters. `mkvmerge -J` is used whenever it
/// is available (it understands Matroska best and also reads MP4, AVI, TS…); `ffprobe` covers
/// files mkvmerge does not recognize, or Macs without MKVToolNix.
public struct MediaInspector: Sendable {
    public let tools: ToolLocator

    public init(tools: ToolLocator) { self.tools = tools }

    public func inspect(_ url: URL) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaInspectionError.notFound }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let mkvmerge = tools.locate(.mkvmerge) {
            let result = try await ProcessRunner.run(mkvmerge, ["-J", url.path])
            if let info = try? Self.parseMKVMerge(result.stdout, url: url, size: size), !info.tracks.isEmpty {
                return info
            }
        }
        guard let ffprobe = tools.locate(.ffprobe) else {
            if tools.locate(.mkvmerge) == nil { throw ToolError.missing(.mkvmerge) }
            throw MediaInspectionError.unreadable(String(localized: "O mkvmerge não reconheceu o arquivo e o ffprobe não está instalado."))
        }
        let result = try await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path])
        guard result.exitCode == 0 else {
            throw MediaInspectionError.unreadable(ProcessRunner.lastMeaningfulLines(result.stderr))
        }
        return try Self.parseFFprobe(result.stdout, url: url, size: size)
    }

    // MARK: mkvmerge -J

    static func parseMKVMerge(_ data: Data, url: URL, size: Int64) throws -> MediaInfo {
        let json = try JSONDecoder().decode(MKVMergeIdentification.self, from: data)
        if json.container?.recognized == false || !(json.errors ?? []).isEmpty {
            throw MediaInspectionError.unreadable((json.errors ?? []).joined(separator: " "))
        }
        let tracks = (json.tracks ?? []).map { t -> MediaTrack in
            let p = t.properties
            let dimensions = p?.pixel_dimensions?.split(separator: "x").compactMap { Int($0) }
            return MediaTrack(
                id: t.id,
                kind: MediaTrack.Kind(rawValue: t.type) ?? .other,
                codec: t.codec ?? "",
                codecID: p?.codec_id ?? t.codec ?? "",
                language: p?.language ?? "und",
                languageIETF: p?.language_ietf,
                name: p?.track_name,
                isDefault: p?.default_track ?? false,
                isForced: p?.forced_track ?? false,
                width: dimensions?.first,
                height: dimensions?.dropFirst().first,
                channels: p?.audio_channels,
                sampleRate: p?.audio_sampling_frequency)
        }
        let attachments = (json.attachments ?? []).map {
            MediaAttachment(id: $0.id, fileName: $0.file_name ?? "", mimeType: $0.content_type ?? "", size: $0.size ?? 0)
        }
        let properties = json.container?.properties
        return MediaInfo(
            url: url,
            container: json.container?.type ?? String(localized: "Desconhecido"),
            title: properties?.title,
            durationMilliseconds: properties?.duration.map { Int($0 / 1_000_000) },
            fileSize: size,
            tracks: tracks,
            attachments: attachments,
            chapterCount: (json.chapters ?? []).reduce(0) { $0 + ($1.num_entries ?? 0) },
            warnings: json.warnings ?? [])
    }

    private struct MKVMergeIdentification: Decodable {
        struct Container: Decodable {
            struct Properties: Decodable {
                let duration: Int64?
                let title: String?
            }
            let type: String?
            let recognized: Bool?
            let properties: Properties?
        }
        struct Track: Decodable {
            struct Properties: Decodable {
                let codec_id: String?
                let language: String?
                let language_ietf: String?
                let track_name: String?
                let default_track: Bool?
                let forced_track: Bool?
                let pixel_dimensions: String?
                let audio_channels: Int?
                let audio_sampling_frequency: Int?
            }
            let id: Int
            let type: String
            let codec: String?
            let properties: Properties?
        }
        struct Attachment: Decodable {
            let id: Int
            let file_name: String?
            let content_type: String?
            let size: Int64?
        }
        struct Chapters: Decodable { let num_entries: Int? }
        let container: Container?
        let tracks: [Track]?
        let attachments: [Attachment]?
        let chapters: [Chapters]?
        let errors: [String]?
        let warnings: [String]?
    }

    // MARK: ffprobe

    static func parseFFprobe(_ data: Data, url: URL, size: Int64) throws -> MediaInfo {
        let json = try JSONDecoder().decode(FFprobeOutput.self, from: data)
        var tracks: [MediaTrack] = []
        var attachments: [MediaAttachment] = []
        for s in json.streams ?? [] {
            let kind: MediaTrack.Kind
            switch s.codec_type {
            case "video" where s.disposition?.attached_pic != 1: kind = .video
            case "audio": kind = .audio
            case "subtitle": kind = .subtitles
            case "attachment":
                attachments.append(MediaAttachment(id: s.index, fileName: s.tags?.filename ?? "", mimeType: s.tags?.mimetype ?? "", size: 0))
                continue
            default: kind = .other
            }
            tracks.append(MediaTrack(
                id: s.index, kind: kind, codec: s.codec_long_name ?? s.codec_name ?? "", codecID: s.codec_name ?? "",
                language: s.tags?.language ?? "und", languageIETF: nil, name: s.tags?.title,
                isDefault: s.disposition?.default == 1, isForced: s.disposition?.forced == 1,
                width: s.width, height: s.height, channels: s.channels, sampleRate: s.sample_rate.flatMap { Int($0) }))
        }
        let duration = json.format?.duration.flatMap(Double.init).map { Int($0 * 1_000) }
        return MediaInfo(url: url, container: json.format?.format_long_name ?? json.format?.format_name ?? String(localized: "Desconhecido"),
                         title: json.format?.tags?.title, durationMilliseconds: duration, fileSize: size,
                         tracks: tracks, attachments: attachments, chapterCount: json.chapters?.count ?? 0)
    }

    private struct FFprobeOutput: Decodable {
        struct Stream: Decodable {
            struct Tags: Decodable { let language: String?; let title: String?; let filename: String?; let mimetype: String? }
            struct Disposition: Decodable { let `default`: Int?; let forced: Int?; let attached_pic: Int? }
            let index: Int
            let codec_type: String?
            let codec_name: String?
            let codec_long_name: String?
            let width: Int?
            let height: Int?
            let channels: Int?
            let sample_rate: String?
            let tags: Tags?
            let disposition: Disposition?
        }
        struct Format: Decodable {
            struct Tags: Decodable { let title: String? }
            let format_name: String?
            let format_long_name: String?
            let duration: String?
            let tags: Tags?
        }
        struct Chapter: Decodable { let id: Int? }
        let streams: [Stream]?
        let format: Format?
        let chapters: [Chapter]?
    }
}
