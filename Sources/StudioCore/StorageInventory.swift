import Foundation

/// What the app keeps on disk, grouped so each kind can be seen and cleared on its own.
/// Nothing here touches the user's media or the files the app created next to it.
public struct StorageInventory: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case previews, fonts, work, dubs, projects, voiceModels, speakerModels

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .previews: "Pré-visualizações"
            case .fonts: "Fontes extraídas"
            case .work: "Arquivos temporários"
            case .dubs: "Arquivos de dublagem"
            case .projects: "Projetos (legendas e traduções)"
            case .voiceModels: "Modelos de voz (Chatterbox)"
            case .speakerModels: "Modelos de identificação de falantes"
            }
        }

        public var detail: String {
            switch self {
            case .previews: "Cópias leves dos vídeos para tocar no app. São recriadas ao abrir o episódio."
            case .fonts: "Fontes dos MKVs para a pré-visualização fiel. São extraídas de novo quando preciso."
            case .work: "Sobras de operações interrompidas."
            case .dubs: "Falas geradas, vozes separadas e música de fundo de cada episódio. Apagar faz a próxima dublagem gerar tudo do zero."
            case .projects: "Legendas extraídas, traduções e revisões de cada episódio. Apagar perde as traduções não incorporadas."
            case .voiceModels: "Baixados na primeira dublagem com a voz original. São baixados de novo quando preciso."
            case .speakerModels: "Baixados na primeira identificação de falantes. São baixados de novo quando preciso."
            }
        }

        /// Clearing loses work the person may want (not just a cache).
        public var losesWork: Bool { self == .projects }
    }

    public struct Entry: Sendable, Identifiable, Hashable {
        public let kind: Kind
        public let bytes: Int64
        public var id: String { kind.rawValue }
    }

    /// Folders that hold each kind. Dubs live inside the projects, one `Dub` folder each.
    public func folders(_ kind: Kind) -> [URL] {
        switch kind {
        case .previews: [paths.previews]
        case .fonts: [paths.caches.appendingPathComponent("Fonts", isDirectory: true)]
        case .work: [paths.scratch]
        case .dubs: projectFolders().map { $0.appendingPathComponent("Dub", isDirectory: true) }
        case .projects: [paths.projects]
        case .voiceModels: [paths.voiceModels, paths.legacyVoiceModels, paths.voiceTokenizer]
        case .speakerModels: [paths.diarizationModels]
        }
    }

    public func entries() -> [Entry] {
        Kind.allCases.map { kind in
            var bytes = folders(kind).reduce(Int64(0)) { $0 + Self.size(of: $1) }
            // Projects are shown without their dub files, which have their own line.
            if kind == .projects { bytes -= folders(.dubs).reduce(Int64(0)) { $0 + Self.size(of: $1) } }
            return Entry(kind: kind, bytes: max(0, bytes))
        }
    }

    public func clear(_ kind: Kind, except busyProjects: Set<String> = []) throws {
        for folder in folders(kind) where FileManager.default.fileExists(atPath: folder.path) {
            if kind == .dubs || kind == .projects, busyProjects.contains(projectID(of: folder)) { continue }
            if kind == .projects {
                for project in projectFolders() where !busyProjects.contains(project.lastPathComponent) {
                    try FileManager.default.removeItem(at: project)
                }
            } else {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// The dub files of one episode.
    public func dubDirectory(projectID: String) -> URL {
        paths.projects.appendingPathComponent(projectID, isDirectory: true).appendingPathComponent("Dub", isDirectory: true)
    }

    private func projectID(of folder: URL) -> String {
        folder.lastPathComponent == "Dub" ? folder.deletingLastPathComponent().lastPathComponent : folder.lastPathComponent
    }

    private func projectFolders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: paths.projects, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Allocated size of a file or folder (0 when missing).
    public static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
