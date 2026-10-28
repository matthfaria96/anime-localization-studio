import MediaKit
import Observation
import StudioCore
import SwiftUI
import TranslationKit
import UniformTypeIdentifiers

/// The three pages of the open video, switched at the top of the window.
enum EpisodeScreen: String, CaseIterable, Identifiable {
    case overview, subtitles, dubbing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: "Visão geral"
        case .subtitles: "Legendar"
        case .dubbing: "Dublar"
        }
    }
    var systemImage: String {
        switch self {
        case .overview: "film"
        case .subtitles: "captions.bubble"
        case .dubbing: "waveform.and.person.filled"
        }
    }
    var hint: String {
        switch self {
        case .overview: "Dados e faixas do vídeo: tamanho, codecs, áudio e legenda padrão, extração."
        case .subtitles: "Corrigir uma legenda do vídeo ou criar uma nova a partir de outra."
        case .dubbing: "Criar uma faixa de áudio dublada com a voz de cada personagem (ElevenLabs, ou no Mac a partir de uma legenda)."
        }
    }
}

/// App-wide state: settings, series and the one video currently open.
@Observable
final class AppModel {
    let paths = AppPaths()
    var screen: EpisodeScreen = .overview
    var workspace: WorkspaceModel?
    var series: [Series] = []
    var toolStatuses: [ToolStatus] = []
    var alert: AppAlert?
    let activity = ProjectActivity()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            // The track is named after its language unless the person typed another name.
            if settings.targetLanguage != oldValue.targetLanguage, settings.trackName == Languages.name(for: oldValue.targetLanguage) {
                settings.trackName = Languages.name(for: settings.targetLanguage)
            }
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
        series = SeriesStore(paths: paths).all()
    }

    var tools: ToolLocator { settings.toolLocator }

    nonisolated static func apiKey(for settings: AppSettings) -> String? {
        guard settings.engine == .openAICompatible else { return nil }
        let key = KeychainStore.read(KeychainStore.account(for: settings.openAI.baseURL))
        if let key { LogRedactor.register(secret: key) }
        return key
    }

    // MARK: ElevenLabs

    static let elevenLabsAccount = "api.elevenlabs.io"

    /// The person's ElevenLabs key, kept only in the Keychain.
    var elevenLabsKey: String? {
        _ = elevenLabsKeyRevision
        let key = KeychainStore.read(Self.elevenLabsAccount)
        if let key, !key.isEmpty { LogRedactor.register(secret: key); return key }
        return nil
    }

    /// Bumped when the key changes, so views reading `elevenLabsKey` update.
    var elevenLabsKeyRevision = 0

    func saveElevenLabsKey(_ key: String) throws {
        try KeychainStore.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.elevenLabsAccount)
        elevenLabsKeyRevision += 1
    }

    func makeEngine() -> any TranslationEngine { settings.makeEngine(apiKey: Self.apiKey(for: settings)) }

    // MARK: Opening media

    /// Opens a video in place of the current one (asking first about unsaved subtitle edits).
    func open(_ url: URL) {
        if let workspace, workspace.hasUnsavedSubtitleChanges(on: screen) {
            workspace.pendingLeave = .open(url)
            return
        }
        openNow(url)
    }

    func openNow(_ url: URL) {
        workspace?.close()
        let workspace = WorkspaceModel(url: url, app: self)
        self.workspace = workspace
        screen = EpisodeScreen(rawValue: ProcessInfo.processInfo.environment["ALS_MODE"] ?? "") ?? .overview
        Task { await workspace.load() }
    }

    /// Back to the start screen.
    func closeVideo() {
        if let workspace, workspace.hasUnsavedSubtitleChanges(on: screen) {
            workspace.pendingLeave = .close
            return
        }
        closeVideoNow()
    }

    /// Quits after the question about unsaved changes was answered.
    func quitNow() {
        workspace?.close()
        quitting = true
        NSApp.terminate(nil)
    }

    /// Set once quitting was confirmed, so the app does not ask again.
    var quitting = false

    func closeVideoNow() {
        workspace?.close()
        workspace = nil
        screen = .overview
    }

    /// Switches page; every page loads the video's data again.
    func show(_ target: EpisodeScreen) {
        guard target != screen, let workspace else { return }
        if workspace.hasUnsavedSubtitleChanges(on: screen) {
            workspace.pendingLeave = .screen(target)
            return
        }
        showNow(target)
    }

    func showNow(_ target: EpisodeScreen) {
        screen = target
        guard let workspace else { return }
        Task { await workspace.reload() }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.videoTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Escolha um vídeo (MKV, MP4 ou MOV)"
        panel.prompt = "Abrir"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Accepts exactly one video file dropped on the window.
    func openDropped(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first, !url.hasDirectoryPath else {
            alert = AppAlert(title: "Um vídeo por vez", message: "Solte um único arquivo de vídeo (MKV, MP4 ou MOV). Pastas e vários arquivos não são aceitos.")
            return false
        }
        open(url)
        return true
    }

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
