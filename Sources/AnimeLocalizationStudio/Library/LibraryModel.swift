import Foundation
import Observation
import StudioCore

nonisolated struct LibraryItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let folder: URL
    let size: Int64
    var project: StudioProject?

    var name: String { url.deletingPathExtension().lastPathComponent }
    var relativeFolder: String {
        let path = url.deletingLastPathComponent().path
        return path.hasPrefix(folder.path) ? String(path.dropFirst(folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : path
    }
}

/// Folders of films, series and seasons imported by the person (only their paths are stored).
@Observable
final class LibraryModel {
    private(set) var folders: [URL] = []
    private(set) var items: [LibraryItem] = []
    var selection: Set<LibraryItem.ID> = []
    var isScanning = false
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private weak var app: AppModel?

    nonisolated static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"]

    init(paths: AppPaths) {
        self.paths = paths
        folders = ((try? JSONDecoder().decode([String].self, from: Data(contentsOf: paths.library))) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func attach(to app: AppModel) { self.app = app }

    func add(_ folder: URL) {
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        persist()
        Task { await scan() }
    }

    func remove(_ folder: URL) {
        folders.removeAll { $0 == folder }
        persist()
        Task { await scan() }
    }

    func scan() async {
        isScanning = true
        let folders = folders
        let store = ProjectStore(paths: paths)
        let found = await Task.detached(priority: .userInitiated) { () -> [LibraryItem] in
            var result: [LibraryItem] = []
            for folder in folders {
                let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let url = enumerator?.nextObject() as? URL {
                    guard Self.videoExtensions.contains(url.pathExtension.lowercased()),
                          !url.deletingPathExtension().lastPathComponent.hasSuffix("[PT-BR]") else { continue }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    result.append(LibraryItem(url: url, folder: folder, size: size, project: store.existingProject(for: url)))
                }
            }
            return result.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }.value
        items = found
        isScanning = false
    }

    func refreshStatuses() {
        let store = ProjectStore(paths: paths)
        items = items.map { item in
            var copy = item
            copy.project = store.existingProject(for: item.url)
            return copy
        }
    }

    var selectedURLs: [URL] { items.filter { selection.contains($0.id) }.map(\.url) }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try JSONEncoder().encode(folders.map(\.path)).write(to: paths.library, options: .atomic)
        } catch {
            app?.report(error, context: "Biblioteca não salva")
        }
    }
}
