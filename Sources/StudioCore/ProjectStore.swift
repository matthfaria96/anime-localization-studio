import CryptoKit
import DubbingKit
import Foundation
import MediaKit
import SubtitleKit
import TranslationKit

public enum WorkStatus: String, Sendable, Codable, CaseIterable {
    case new, extracted, translating, translated, reviewed, muxed, failed

    public var label: String {
        switch self {
        case .new: "Novo"
        case .extracted: "Legenda extraída"
        case .translating: "Traduzindo"
        case .translated: "Traduzido"
        case .reviewed: "Revisado"
        case .muxed: "Faixa incorporada"
        case .failed: "Falhou"
        }
    }
}

/// Everything the app knows about one media file: chosen source track, working subtitle
/// files, translation state and the last export. Stored as JSON in its own folder.
public struct StudioProject: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var mediaPath: String
    public var title: String
    public var seriesID: UUID?
    public var sourceTrackID: Int?
    public var sourceFormat: SubtitleFormat?
    /// An external subtitle file used instead of an embedded track.
    public var externalSubtitlePath: String?
    public var translationStatus: WorkStatus
    public var dubbingStatus: WorkStatus
    public var lastReport: TranslationReport?
    public var lastOutputPath: String?
    public var lastVerification: VerificationReport?
    public var lastDubReport: DubbingReport?
    /// Voice cast for films and episodes that are not part of a series.
    public var cast: VoiceCast?
    public var createdAt: Date
    public var updatedAt: Date

    public var mediaURL: URL { URL(fileURLWithPath: mediaPath) }

    public static func id(for mediaURL: URL) -> String {
        SHA256.hash(data: Data(mediaURL.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProjectStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func directory(for id: String) -> URL { paths.projects.appendingPathComponent(id, isDirectory: true) }
    private func file(for id: String) -> URL { directory(for: id).appendingPathComponent("project.json") }

    /// The existing project for a file, or a new one (not yet saved).
    public func project(for mediaURL: URL) -> StudioProject {
        let id = StudioProject.id(for: mediaURL)
        do {
            if let saved = try JSONFile.read(StudioProject.self, from: file(for: id)) { return saved }
        } catch {
            // Unreadable (corrupt or from an incompatible version): keep it aside, never overwrite it.
            let aside = file(for: id).deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file(for: id), to: aside)
            AppLog.shared.error("project.json ilegível movido para \(aside.lastPathComponent): \(error.localizedDescription)")
        }
        return StudioProject(id: id, mediaPath: mediaURL.standardizedFileURL.path, title: mediaURL.deletingPathExtension().lastPathComponent,
                             translationStatus: .new, dubbingStatus: .new, createdAt: Date(), updatedAt: Date())
    }

    public func existingProject(for mediaURL: URL) -> StudioProject? {
        try? JSONFile.read(StudioProject.self, from: file(for: StudioProject.id(for: mediaURL)))
    }

    public func save(_ project: StudioProject) throws {
        var copy = project
        copy.updatedAt = Date()
        try JSONFile.write(copy, to: file(for: project.id))
    }

    public func all() -> [StudioProject] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: paths.projects, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { try? JSONFile.read(StudioProject.self, from: $0.appendingPathComponent("project.json")) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Working files

    public func sourceSubtitleURL(for project: StudioProject) -> URL? {
        guard let format = project.sourceFormat else { return nil }
        return directory(for: project.id).appendingPathComponent("source.\(format.fileExtension)")
    }

    public func translationURL(for project: StudioProject, language: String = "pt-BR") -> URL? {
        guard let format = project.sourceFormat else { return nil }
        return directory(for: project.id).appendingPathComponent("translation.\(language).\(format.fileExtension)")
    }

    public func checkpointURL(for project: StudioProject, language: String = "pt-BR") -> URL {
        directory(for: project.id).appendingPathComponent("checkpoint.\(language).json")
    }

    /// Copy of the working translation taken before an operation that replaces it.
    public func backupTranslation(of project: StudioProject, language: String = "pt-BR") throws {
        guard let url = translationURL(for: project, language: language), FileManager.default.fileExists(atPath: url.path) else { return }
        let backups = directory(for: project.id).appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let unique = UUID().uuidString.prefix(8)
        try FileManager.default.copyItem(at: url, to: backups.appendingPathComponent("\(stamp)-\(unique)-\(url.lastPathComponent)"))
    }
}

/// A series (or film collection) shares one glossary and, later, one voice cast.
public struct Series: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var glossary: Glossary
    /// Voices of the series' characters, reused by every episode. Optional so series saved
    /// before casting existed still load.
    public var cast: VoiceCast?

    public init(id: UUID = UUID(), name: String, glossary: Glossary = Glossary(), cast: VoiceCast? = nil) {
        self.id = id
        self.name = name
        self.glossary = glossary
        self.cast = cast
    }
}

public struct SeriesStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    private func file(for id: UUID) -> URL { paths.series.appendingPathComponent("\(id.uuidString).json") }

    public func all() -> [Series] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.series, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONFile.read(Series.self, from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func series(_ id: UUID) -> Series? { try? JSONFile.read(Series.self, from: file(for: id)) }
    public func save(_ series: Series) throws { try JSONFile.write(series, to: file(for: series.id)) }
    public func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: file(for: id)) }
}
