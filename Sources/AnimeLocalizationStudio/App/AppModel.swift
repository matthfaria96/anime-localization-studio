import MediaKit
import Observation
import StudioCore
import SwiftUI
import TranslationKit
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case workspace, dubbing, library, queue, series, diagnostics
}

/// App-wide state: settings, stores, the job queue and the episode currently open.
@Observable
final class AppModel {
    let paths = AppPaths()
    var selection: SidebarItem? = .workspace
    var workspace: WorkspaceModel?
    var series: [Series] = []
    var toolStatuses: [ToolStatus] = []
    var recentProjects: [StudioProject] = []
    var alert: AppAlert?
    let library: LibraryModel
    let queue: JobQueue
    let activity: ProjectActivity

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsBox.value = settings
            do { try SettingsStore(paths: paths).save(settings) } catch { report(error, context: "Ajustes não salvos") }
        }
    }

    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "mkv") ?? .movie,
                                       UTType(filenameExtension: "webm") ?? .movie, .avi]
    static let subtitleTypes: [UTType] = ["ass", "ssa", "srt"].compactMap { UTType(filenameExtension: $0) }

    init() {
        let paths = AppPaths()
        let loaded = SettingsStore(paths: paths).load()
        settings = loaded
        library = LibraryModel(paths: paths)
        let settingsBox = SettingsBox(loaded)
        let activity = ProjectActivity()
        self.activity = activity
        queue = JobQueue(file: paths.jobs, performer: EpisodeJobPerformer(
            paths: paths,
            settings: { settingsBox.value },
            apiKey: { AppModel.apiKey(for: $0) }), activity: activity)
        self.settingsBox = settingsBox
        series = SeriesStore(paths: paths).all()
        recentProjects = ProjectStore(paths: paths).all()
        library.attach(to: self)
    }

    /// Mirrors `settings` for the queue, which runs outside the main actor.
    private let settingsBox: SettingsBox

    var tools: ToolLocator { settings.toolLocator }

    nonisolated static func apiKey(for settings: AppSettings) -> String? {
        guard settings.engine == .openAICompatible else { return nil }
        let key = KeychainStore.read(KeychainStore.account(for: settings.openAI.baseURL))
        if let key { LogRedactor.register(secret: key) }
        return key
    }

    func makeEngine() -> any TranslationEngine { settings.makeEngine(apiKey: Self.apiKey(for: settings)) }

    // MARK: Opening media

    func open(_ url: URL) {
        let workspace = WorkspaceModel(url: url, app: self)
        self.workspace = workspace
        selection = ProcessInfo.processInfo.environment["ALS_MODE"] == "dubbing" ? .dubbing : .workspace
        Task { await workspace.load() }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.videoTypes
        panel.allowsMultipleSelection = false
        panel.message = "Escolha um filme, episódio ou arquivo MKV"
        panel.prompt = "Abrir"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func refreshRecents() { recentProjects = ProjectStore(paths: paths).all() }

    // MARK: Diagnostics

    func refreshTools() async {
        toolStatuses = await tools.diagnose()
    }

    var missingTools: [ToolStatus] { toolStatuses.filter { !$0.isAvailable } }

    // MARK: Series

    func saveSeries(_ value: Series) {
        do {
            try SeriesStore(paths: paths).save(value)
            series = SeriesStore(paths: paths).all()
        } catch { report(error, context: "Série não salva") }
    }

    func deleteSeries(_ id: UUID) {
        try? SeriesStore(paths: paths).delete(id)
        series = SeriesStore(paths: paths).all()
    }

    func glossary(for seriesID: UUID?) -> Glossary {
        seriesID.flatMap { id in series.first { $0.id == id } }?.glossary ?? Glossary()
    }

    // MARK: Errors

    func report(_ error: Error, context: String) {
        let message = LogRedactor.redact(error.localizedDescription)
        AppLog.shared.error("\(context): \(message)")
        alert = AppAlert(title: context, message: message)
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

nonisolated final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppSettings
    init(_ value: AppSettings) { stored = value }
    var value: AppSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
