import AppKit
import DubbingKit
import MediaKit
import Observation
import StudioCore
import SubtitleKit
import TranslationKit
import UniformTypeIdentifiers

struct RunningOperation: Equatable {
    enum Kind { case loading, translating, muxing, extracting }
    let kind: Kind
    var fraction: Double?
    var message: String
}

/// One open media file: its tracks, project, preview player and subtitle editor.
@Observable
final class WorkspaceModel {
    let url: URL
    @ObservationIgnored unowned let app: AppModel
    let player = PlayerModel()
    let editor = EditorModel()
    var project: StudioProject
    var info: MediaInfo?
    var loadError: String?
    var operation: RunningOperation?
    var notice: (kind: InlineMessage.Kind, text: String)?
    var lastReport: TranslationReport?
    var lastMux: (url: URL, report: VerificationReport)?
    var overlayMode: OverlayMode = .translation
    var previewAudioTrackID: Int?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var editorLoadedSource: SubtitleDocument?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(url: URL, app: AppModel) {
        self.url = url
        self.app = app
        project = ProjectStore(paths: app.paths).project(for: url)
        lastReport = project.lastReport
        editor.onChange = { [weak self] source, translation in self?.writeWorkingFiles(source: source, translation: translation) }
        editor.spellingLanguage = app.settings.targetLanguage.replacingOccurrences(of: "-", with: "_")
        editor.maxReadingSpeed = app.settings.maxReadingSpeed
    }

    var title: String { project.title }
    var audioTracks: [MediaTrack] { info?.tracks(.audio) ?? [] }
    var subtitleTracks: [MediaTrack] { info?.tracks(.subtitles) ?? [] }
    var isBusy: Bool { operation != nil }
    private var store: ProjectStore { ProjectStore(paths: app.paths) }

    private func workflow() -> EpisodeWorkflow {
        EpisodeWorkflow(paths: app.paths, settings: app.settings, engine: app.makeEngine(), glossary: app.glossary(for: project.seriesID))
    }

    // MARK: Loading

    func load() async {
        operation = RunningOperation(kind: .loading, fraction: nil, message: "Analisando faixas…")
        do {
            let info = try await MediaInspector(tools: app.tools).inspect(url)
            self.info = info
            previewAudioTrackID = info.tracks(.audio).first(where: \.isDefault)?.id ?? info.tracks(.audio).first?.id
            startPreview()
            await loadSubtitles()
            operation = nil
            applyTestHooks()
        } catch {
            operation = nil
            loadError = error.localizedDescription
        }
    }

    func loadSubtitles() async {
        do {
            let (prepared, _, sourceURL) = try await workflow().prepareSource(project)
            project = prepared
            if project.sourceFormat == nil { project.sourceFormat = SubtitleFormat(fileExtension: sourceURL.pathExtension) }
            let source = try SubtitleDocument.load(sourceURL)
            editorLoadedSource = source
            writtenSource = nil
            let translationURL = store.translationURL(for: project, language: app.settings.targetLanguage)
            let translation = translationURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try? SubtitleDocument.load($0) : nil }
            editor.load(source: source, translation: translation.flatMap { $0.count == source.count ? $0 : nil })
            try? store.save(project)
            app.refreshRecents()
        } catch WorkflowError.noTextSubtitle {
            editor.load(source: nil, translation: nil)
            notice = (.info, "Este arquivo não tem legenda de texto embutida. Abra uma legenda externa (ASS, SSA ou SRT).")
        } catch {
            editor.load(source: nil, translation: nil)
            notice = (.error, error.localizedDescription)
        }
    }

    func startPreview() {
        guard let info else { return }
        previewTask?.cancel()
        let audio = info.tracks.first { $0.id == previewAudioTrackID }
        previewTask = Task { await player.prepare(info: info, audioTrack: audio, tools: app.tools, cache: app.paths.previews) }
    }

    func selectPreviewAudio(_ id: Int?) {
        guard id != previewAudioTrackID else { return }
        previewAudioTrackID = id
        startPreview()
    }

    func selectSourceTrack(_ id: Int) {
        guard id != project.sourceTrackID else { return }
        editor.flush()
        do {
            // The translation belongs to the old track; it is removed only once a copy is safe.
            try store.backupTranslation(of: project, language: app.settings.targetLanguage)
            if let old = store.translationURL(for: project, language: app.settings.targetLanguage) { try? FileManager.default.removeItem(at: old) }
        } catch {
            app.report(error, context: "Troca de faixa cancelada: não foi possível guardar a tradução atual")
            return
        }
        project.sourceTrackID = id
        project.externalSubtitlePath = nil
        project.translationStatus = .new
        Task {
            operation = RunningOperation(kind: .extracting, fraction: nil, message: "Extraindo legenda…")
            await loadSubtitles()
            operation = nil
        }
    }

    func openExternalSubtitle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.subtitleTypes
        panel.message = "Escolha a legenda original (ASS, SSA ou SRT)"
        guard panel.runModal() == .OK, let file = panel.url, let format = SubtitleFormat(fileExtension: file.pathExtension) else { return }
        editor.flush()
        do {
            let copy = store.directory(for: project.id).appendingPathComponent("source.\(format.fileExtension)")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: file, to: copy)
            project.externalSubtitlePath = copy.path
            project.sourceFormat = format
            project.sourceTrackID = nil
            try store.save(project)
            notice = nil
            Task { await loadSubtitles() }
        } catch {
            app.report(error, context: "Legenda não aberta")
        }
    }

    // MARK: Translate

    /// Claims the project for a long operation, or explains why it cannot start.
    private func claim(_ description: String) -> Bool {
        if app.activity.begin(project.id, description) { return true }
        notice = (.warning, "Este episódio já está sendo processado (\(app.activity.activity(for: project.id) ?? "outra tarefa")). Aguarde terminar.")
        return false
    }

    private func release() { app.activity.end(project.id) }

    func translateEpisode(undoManager: UndoManager?, retranslateAll: Bool = false) {
        guard !isBusy, claim("Tradução no estúdio") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .translating, fraction: 0, message: "Preparando tradução…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, report) = try await workflow.translate(project, retranslateAll: retranslateAll) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                lastReport = report
                if let url = store.translationURL(for: updated, language: app.settings.targetLanguage) {
                    editor.applyTranslation(try SubtitleDocument.load(url), undoManager: undoManager)
                    editor.flush()
                }
                overlayMode = .translation
                notice = report.isComplete
                    ? (.success, report.preservedLines > 0
                        ? "Episódio traduzido com \(report.engineName). \(report.preservedLines) falas já traduzidas foram mantidas."
                        : "Episódio traduzido: \(report.translatedLines) falas com \(report.engineName).")
                    : (.warning, "\(report.failedLines.count) falas ficaram sem tradução. Revise-as com o filtro “Sem tradução”.")
            } catch is CancellationError {
                notice = (.info, "Tradução cancelada. O progresso foi salvo e será retomado na próxima vez.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
            app.refreshRecents()
        }
    }

    func cancelOperation() { task?.cancel() }

    // MARK: Mux

    func embedTranslation() {
        guard !isBusy, editor.translation != nil, claim("Incorporação no estúdio") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando incorporação…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, output, report) = try await workflow.mux(project) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                lastMux = (output, report)
                notice = (.success, "Novo arquivo criado e verificado: \(output.lastPathComponent). O original não foi alterado.")
            } catch is CancellationError {
                notice = (.info, "Incorporação cancelada. Nenhum arquivo foi criado.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    // MARK: Transcription

    /// Set when macOS must download the speech model for a language before transcribing.
    var pendingModelDownload: String?

    func transcribeAudio(language: String, allowModelDownload: Bool = false) {
        guard !isBusy, claim("Transcrição no estúdio") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Preparando transcrição…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let updated = try await workflow.transcribe(project, language: language, allowModelDownload: allowModelDownload) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                if let old = store.translationURL(for: updated, language: app.settings.targetLanguage) { try? FileManager.default.removeItem(at: old) }
                operation = nil
                release()
                await loadSubtitles()
                notice = (.success, "Transcrição pronta: \(editor.rows.count) falas. Os personagens não são identificados automaticamente; revise e traduza.")
                return
            } catch SpeechTranscription.TranscriptionError.modelDownloadRequired(let language) {
                pendingModelDownload = language
            } catch is CancellationError {
                notice = (.info, "Transcrição cancelada.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    var bitmapSubtitleTracks: [MediaTrack] { subtitleTracks.filter(\.isBitmapSubtitle) }

    func recognizeBitmapSubtitle(language: String) {
        guard !isBusy, claim("OCR no estúdio") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Preparando OCR…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, skipped) = try await workflow.recognizeBitmapSubtitle(project, language: language) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                if let old = store.translationURL(for: updated, language: app.settings.targetLanguage) { try? FileManager.default.removeItem(at: old) }
                operation = nil
                release()
                await loadSubtitles()
                notice = (skipped == 0 ? .success : .warning,
                          "Texto reconhecido em \(editor.rows.count) legendas\(skipped > 0 ? "; \(skipped) imagens sem texto legível foram ignoradas" : ""). Revise a ortografia antes de traduzir.")
                return
            } catch is CancellationError {
                notice = (.info, "OCR cancelado.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    // MARK: Dub

    var lastDub: (url: URL, report: DubbingReport, verification: VerificationReport)?

    /// The cast of the series (shared by its episodes) or, without a series, of this project.
    func loadCast() -> VoiceCast {
        if let id = project.seriesID, let series = app.series.first(where: { $0.id == id }) { return series.cast ?? VoiceCast() }
        return project.cast ?? VoiceCast()
    }

    func saveCast(_ cast: VoiceCast) {
        if let id = project.seriesID, var series = app.series.first(where: { $0.id == id }) {
            series.cast = cast
            app.saveSeries(series)
        } else {
            project.cast = cast
            try? store.save(project)
        }
    }

    func dubEpisode(cast: VoiceCast) {
        guard !isBusy, editor.translation != nil, claim("Dublagem no estúdio") else { return }
        editor.flush()
        saveCast(cast)
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando dublagem…")
        let workflow = workflow()
        let project = project
        let synthesizer = app.settings.makeSynthesizer()
        task = Task {
            do {
                let (updated, output, report, verification) = try await workflow.dub(project, synthesizer: synthesizer, cast: cast) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                lastDub = (output, report, verification)
                lastMux = (output, verification)
                notice = report.failed.isEmpty
                    ? (.success, "Dublagem pronta: \(output.lastPathComponent). O áudio e a legenda originais continuam no arquivo.")
                    : (.warning, "Dublagem criada com \(report.failed.count) falas sem voz. Veja a lista de revisão.")
            } catch is CancellationError {
                notice = (.info, "Dublagem cancelada. As vozes já geradas ficam guardadas e serão reaproveitadas.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    func exportTranslation() {
        guard let translation = editor.translation, let format = project.sourceFormat else { return }
        editor.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(project.title).\(app.settings.targetLanguage).\(format.fileExtension)"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try translation.write(to: destination)
            notice = (.success, "Legenda exportada: \(destination.lastPathComponent)")
        } catch {
            app.report(error, context: "Exportação falhou")
        }
    }

    func revealOutput() {
        if let output = lastMux?.url { NSWorkspace.shared.activateFileViewerSelecting([output]) }
    }

    // MARK: Navigation

    func jumpLine(by delta: Int) {
        let rows = editor.rows.filter { !$0.isComment }
        guard !rows.isEmpty else { return }
        let current = editor.selection.first ?? editor.line(at: player.currentTime) ?? -1
        let position = rows.firstIndex { $0.id == current }
        let next = position.map { min(max(0, $0 + delta), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        select(rows[next].id, seek: true)
    }

    func select(_ id: Int, seek: Bool) {
        editor.selection = [id]
        if seek, let row = editor.rows.first(where: { $0.id == id }) { player.seek(to: row.start) }
    }

    func assignSeries(_ id: UUID?) {
        project.seriesID = id
        try? store.save(project)
    }

    // MARK: Persistence

    @ObservationIgnored private var writtenSource: SubtitleDocument?

    private func writeWorkingFiles(source: SubtitleDocument?, translation: SubtitleDocument?) {
        do {
            // The original subtitle is rewritten only when it was edited.
            if let source, source != writtenSource ?? editorLoadedSource, let url = store.sourceSubtitleURL(for: project) {
                try source.write(to: url)
                writtenSource = source
                if project.externalSubtitlePath != nil { project.externalSubtitlePath = url.path }
            }
            if let translation, let url = store.translationURL(for: project, language: app.settings.targetLanguage) {
                try translation.write(to: url)
                if project.translationStatus == .new || project.translationStatus == .extracted { project.translationStatus = .reviewed }
            }
            try store.save(project)
        } catch {
            app.report(error, context: "Alterações não salvas")
        }
    }

    /// UI test hooks, inert unless set: `ALS_SELECT=<line>`, `ALS_SEEK=<ms>`, `ALS_TRANSLATE=1`, `ALS_DUB=1`.
    /// Used to capture the real window without driving the mouse or keyboard.
    private func applyTestHooks() {
        let env = ProcessInfo.processInfo.environment
        if let line = env["ALS_SELECT"].flatMap(Int.init) { editor.selection = [line - 1] }
        if let ms = env["ALS_SEEK"].flatMap(Int.init) {
            Task {
                while player.state != .ready { try? await Task.sleep(for: .milliseconds(100)) }
                player.seek(to: ms)
            }
        }
        if env["ALS_TRANSLATE"] == "1" { translateEpisode(undoManager: nil) }
        if env["ALS_DUB"] == "1" { dubEpisode(cast: loadCast()) }
    }

    func close() {
        editor.flush()
        task?.cancel()
        previewTask?.cancel()
        player.stop()
    }
}
