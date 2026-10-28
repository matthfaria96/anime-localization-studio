import AppKit
import ASSRendering
import AVFoundation
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
    var notice: (kind: InlineMessage.Kind, text: String)? {
        didSet { if notice?.text != oldValue?.text { noticeAction = nil } }
    }
    var lastReport: TranslationReport?
    var lastMux: (url: URL, report: VerificationReport)?
    var overlayMode: OverlayMode = .translation
    var previewAudioTrackID: Int?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var editorLoadedSource: SubtitleDocument?
    /// libass renderers for the faithful preview (nil if libass could not start).
    @ObservationIgnored let originalRenderer = try? ASSRenderer()
    @ObservationIgnored let translationRenderer = try? ASSRenderer()
    /// Bumped after the renderers load new script text, so overlays redraw.
    var renderRevision = 0
    @ObservationIgnored private var renderedEditorRevision = -1
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(url: URL, app: AppModel) {
        self.url = url
        self.app = app
        project = ProjectStore(paths: app.paths).project(for: url)
        lastReport = project.lastReport
        // Legendar opens straight in the editor: correcting is the default.
        if project.subtitleTask == nil { project.subtitleTask = .edit }
        overlayMode = project.subtitleTask == .edit ? .original : .translation
        editor.editsOriginal = project.subtitleTask == .edit
        editor.onChange = { [weak self] source, translation in self?.writeWorkingFiles(source: source, translation: translation) }
        editor.spellingLanguage = app.settings.targetLanguage.replacingOccurrences(of: "-", with: "_")
        editor.maxReadingSpeed = app.settings.maxReadingSpeed
    }

    var title: String { project.title }
    var audioTracks: [MediaTrack] { info?.tracks(.audio) ?? [] }
    var subtitleTracks: [MediaTrack] { info?.tracks(.subtitles) ?? [] }
    var isBusy: Bool { operation != nil }
    var store: ProjectStore { ProjectStore(paths: app.paths) }

    func workflow() -> EpisodeWorkflow {
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
            Task { await loadEmbeddedFonts(info); await loadAddedFonts() }
            applyTestHooks()
        } catch {
            operation = nil
            loadError = error.localizedDescription
        }
    }

    func loadSubtitles() async {
        // Whatever is loaded now is the starting point that “Descartar” goes back to.
        defer { beginSubtitleSession() }
        do {
            let (prepared, _, sourceURL) = try await workflow().prepareSource(project)
            project = prepared
            if project.sourceFormat == nil { project.sourceFormat = SubtitleFormat(fileExtension: sourceURL.pathExtension) }
            let speakers = project.lineSpeakers ?? [:]
            let source = try SubtitleDocument.load(sourceURL).withSideSpeakers(speakers)
            editorLoadedSource = source
            cast = loadCast()
            writtenSource = nil
            let translationURL = store.translationURL(for: project, language: app.settings.targetLanguage)
            let translation = translationURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try? SubtitleDocument.load($0) : nil }?
                .withSideSpeakers(speakers)
            editor.load(source: source, translation: translation.flatMap { $0.count == source.count ? $0 : nil })
            try? store.save(project)
            await loadReference()
            await loadDubText()
        } catch WorkflowError.noTextSubtitle {
            editor.load(source: nil, translation: nil)
            notice = (.info, "Este arquivo não tem legenda de texto embutida. Abra uma legenda externa (ASS, SSA ou SRT).")
        } catch {
            editor.load(source: nil, translation: nil)
            notice = (.error, error.localizedDescription)
        }
    }

    // MARK: Faithful preview (libass)

    var usesFaithfulPreview: Bool {
        guard app.settings.faithfulPreview, originalRenderer != nil, let source = editor.source else { return false }
        return !source.usesHTMLMarkup
    }

    /// Feeds the current documents to libass after an edit.
    func refreshRenderers() async {
        guard usesFaithfulPreview, renderedEditorRevision != editor.revision, let source = editor.source else { return }
        renderedEditorRevision = editor.revision
        let original = source.encoded()
        let translated = (editor.translation ?? source).encoded()
        try? await originalRenderer?.load(script: original)
        try? await translationRenderer?.load(script: translated)
        renderRevision += 1
    }

    /// Extracts the MKV's font attachments once and gives them to libass, so the preview uses
    /// the fonts the fansub chose.
    private func loadEmbeddedFonts(_ info: MediaInfo) async {
        let fonts = info.attachments.filter(\.isFont)
        guard !fonts.isEmpty, originalRenderer != nil, let mkvextract = app.tools.locate(.mkvextract) else { return }
        let directory = app.paths.caches.appendingPathComponent("Fonts/\(project.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = fonts.filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
        if !missing.isEmpty {
            let specs = missing.map { "\($0.id):\(directory.appendingPathComponent($0.fileName).path)" }
            _ = try? await ProcessRunner.run(mkvextract, [info.url.path, "attachments"] + specs)
        }
        for font in fonts {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(font.fileName)) else { continue }
            await originalRenderer?.addFont(named: font.fileName, data: data)
            await translationRenderer?.addFont(named: font.fileName, data: data)
        }
        renderRevision += 1
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

    func openExternalSubtitle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.subtitleTypes
        panel.message = "Escolha o arquivo de legenda (ASS, SSA ou SRT)"
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
            Task { await reload() }
        } catch {
            app.report(error, context: "Legenda não aberta")
        }
    }

    // MARK: Tracks of the file

    /// Default audio/subtitle chosen in the inspector, not yet written to the file.
    var pendingDefaults: TrackFlagEditor.Defaults?
    /// Asks “new file or replace the original?” before muxing.
    var askEmbedDestination = false
    /// Same question before saving an edited subtitle back into the MKV.
    var askSaveEditedDestination = false
    /// Glossaries and series notes, opened from Legendar.
    var showSeries = false
    /// “Criar a partir do áudio” window.
    var showFromAudio = false
    /// The track whose deletion is being confirmed in the Visão geral.
    var trackToDelete: MediaTrack?
    /// Where the person wanted to go when Legendar had unsaved changes (asks save or discard).
    var pendingLeave: LeaveTarget?
    /// The subtitles as they were when Legendar loaded them.
    @ObservationIgnored var sessionSource: SubtitleDocument?
    @ObservationIgnored var sessionTranslation: SubtitleDocument?
    var sessionRevision = 0
    @ObservationIgnored var sessionDraftPending = false
    /// Asks “this file or a copy?” before writing default-track changes.
    var askDefaultsDestination = false
    /// Optional button shown with the notice (e.g. open the file just created).
    var noticeAction: (title: String, run: () -> Void)?

    var currentDefaults: TrackFlagEditor.Defaults {
        TrackFlagEditor.Defaults(audioTrackID: info?.tracks(.audio).first(where: \.isDefault)?.id,
                                 subtitleTrackID: info?.tracks(.subtitles).first(where: \.isDefault)?.id ?? -1)
    }

    var effectiveDefaults: TrackFlagEditor.Defaults { pendingDefaults ?? currentDefaults }
    var hasPendingDefaults: Bool { pendingDefaults != nil && pendingDefaults != currentDefaults }

    func applyDefaults(inPlace: Bool) {
        guard let defaults = pendingDefaults, !isBusy, claim("Faixas padrão") else { return }
        editor.flush()
        operation = RunningOperation(kind: .muxing, fraction: nil, message: inPlace ? "Alterando as faixas padrão…" : "Criando a cópia com as novas faixas padrão…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, url) = try await workflow.applyDefaultTracks(project, defaults: defaults, inPlace: inPlace)
                self.project = updated
                pendingDefaults = nil
                release()
                operation = nil
                if inPlace {
                    await reload()
                    notice = (.success, "Faixas padrão alteradas no próprio arquivo, sem regravar o vídeo.")
                } else {
                    notice = (.success, "Cópia criada com as novas faixas padrão: \(url.lastPathComponent). O original não mudou.")
                    noticeAction = ("Abrir a cópia", { [app] in app.open(url) })
                }
                return
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    /// Re-reads the file's tracks and the project's subtitles after anything changed them.
    func reload() async {
        let resume = player.currentTime
        do {
            let fresh = try await MediaInspector(tools: app.tools).inspect(url)
            let fileChanged = fresh.fileSize != info?.fileSize || fresh.tracks.count != info?.tracks.count
            info = fresh
            if !fresh.tracks(.audio).contains(where: { $0.id == previewAudioTrackID }) {
                previewAudioTrackID = fresh.tracks(.audio).first(where: \.isDefault)?.id ?? fresh.tracks(.audio).first?.id
            }
            project = store.project(for: url)
            await loadSubtitles()
            if fileChanged {
                try? PreviewProxy(tools: app.tools, cacheDirectory: app.paths.previews).clearCache()
                startPreview()
            }
            if resume > 0 { player.seek(to: resume) }
        } catch {
            notice = (.error, error.localizedDescription)
        }
    }

    // MARK: Linking a translation

    var linkableTracks: [MediaTrack] {
        subtitleTracks.filter { $0.textSubtitleExtension != nil && $0.id != project.sourceTrackID }
    }

    func linkTranslation(track: MediaTrack?, file: URL? = nil, undoManager: UndoManager?) {
        guard !isBusy, claim("Vincular tradução") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: nil, message: "Vinculando a tradução…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, result) = try await workflow.linkTranslation(project, track: track, file: file)
                self.project = updated
                editor.applyTranslation(result.document, undoManager: undoManager)
                editor.flush()
                overlayMode = .translation
                notice = (result.matched == result.total ? .success : .warning,
                          "Tradução vinculada: \(result.matched) de \(result.total) falas encontraram correspondência pelo tempo\(result.matched < result.total ? "; as outras ficaram no original" : ""). ⌘Z desfaz.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    func linkTranslationFile(undoManager: UndoManager?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.subtitleTypes
        panel.message = "Escolha a legenda traduzida (ASS, SSA ou SRT) para editar ao lado do original"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        linkTranslation(track: nil, file: file, undoManager: undoManager)
    }

    // MARK: Translate

    /// Claims the project for a long operation, or explains why it cannot start.
    func claim(_ description: String) -> Bool {
        if app.activity.begin(project.id, description) { return true }
        notice = (.warning, "Este episódio já está sendo processado (\(app.activity.activity(for: project.id) ?? "outra tarefa")). Aguarde terminar.")
        return false
    }

    func release() { app.activity.end(project.id) }

    func translateEpisode(undoManager: UndoManager?, retranslateAll: Bool = false) {
        guard !isBusy, claim("Tradução") else { return }
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
        }
    }

    func cancelOperation() { task?.cancel() }

    // MARK: Mux

    /// Asks where to write before muxing.
    func requestEmbed() {
        guard !isBusy, editor.translation != nil else { return }
        askEmbedDestination = true
    }

    func embedTranslation(replaceOriginal: Bool = false) {
        guard !isBusy, editor.translation != nil, claim("Gravar a legenda no vídeo") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando a gravação…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, output, report) = try await workflow.mux(project, replaceOriginal: replaceOriginal) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                self.project.draftPending = false
                try? store.save(self.project)
                beginSubtitleSession()
                lastMux = (output, report)
                if replaceOriginal {
                    release()
                    operation = nil
                    await reload()
                    notice = (.success, "Legenda gravada neste arquivo e verificada. A versão anterior do arquivo está na Lixeira.")
                    return
                }
                notice = (.success, "Novo arquivo criado e verificado: \(output.lastPathComponent). O original não foi alterado.")
                noticeAction = ("Abrir o novo arquivo", { [app] in app.open(output) })
            } catch is CancellationError {
                notice = (.info, "Gravação cancelada. Nenhum arquivo foi criado ou alterado.")
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
    /// Runs the transcription again once the person agrees to the model download.
    @ObservationIgnored var transcriptionRetry: (() -> Void)?
    /// Set when the speaker-identification models must be downloaded first: the action to retry.
    var pendingDiarizationDownload: (() -> Void)?

    func transcribeAudio(language: String, allowModelDownload: Bool = false, identifySpeakers: Bool = false, allowDiarizationDownload: Bool = false,
                         audioTrackID: Int? = nil, then: (@MainActor () -> Void)? = nil) {
        guard !isBusy, claim("Transcrição") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Preparando transcrição…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let updated = try await workflow.transcribe(project, language: language, allowModelDownload: allowModelDownload,
                                                            identifySpeakers: identifySpeakers, allowDiarizationDownload: allowDiarizationDownload,
                                                            audioTrackID: audioTrackID) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                if let old = store.translationURL(for: updated, language: app.settings.targetLanguage) { try? FileManager.default.removeItem(at: old) }
                operation = nil
                release()
                await loadSubtitles()
                notice = (.success, identifySpeakers
                          ? "Transcrição pronta: \(editor.rows.count) falas. As vozes foram separadas e ficam guardadas para a dublagem; dê o nome de cada personagem em Dublar › Personagens."
                          : "Transcrição pronta: \(editor.rows.count) falas. Revise e traduza.")
                then?()
                return
            } catch SpeechTranscription.TranscriptionError.modelDownloadRequired(let language) {
                pendingModelDownload = language
                transcriptionRetry = {
                    self.transcribeAudio(language: language, allowModelDownload: true, identifySpeakers: identifySpeakers,
                                         allowDiarizationDownload: allowDiarizationDownload, audioTrackID: audioTrackID, then: then)
                }
            } catch SpeakerDiarization.DiarizationError.modelsNotInstalled {
                // Cleared when the consent dialog is answered or dismissed.
                pendingDiarizationDownload = {
                    self.transcribeAudio(language: language, allowModelDownload: allowModelDownload, identifySpeakers: true, allowDiarizationDownload: true,
                                         audioTrackID: audioTrackID, then: then)
                }
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
        guard !isBusy, claim("Reconhecimento de texto (OCR)") else { return }
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

    // MARK: Dub state (actions in WorkspaceModel+Dubbing.swift)

    /// Clips of each speaker's original voice, for “Ouvir original”.
    var voiceSamples: [String: URL] = [:]
    var dubSession: DubSession?
    /// Characters and their voices (of the series, or of this video without a series).
    var cast = VoiceCast() {
        didSet { if cast != oldValue { saveCast(cast) } }
    }
    /// What the dub speaks (loaded from the app's translation or a subtitle of the video).
    var dubText: DubText?
    /// Text of the reference track beside each line being edited (read only).
    var referenceLines: [Int: String] = [:]
    var lastDub: (url: URL, report: DubbingReport, verification: VerificationReport)?
    /// Size of this episode's dub work files, refreshed after dubbing or clearing.
    var dubStorageBytes: Int64 = 0

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

    /// The line above or below in the list as shown (with its filter and search), selected and
    /// with the video taken to it.
    func moveSelection(by delta: Int) {
        let rows = editor.visibleRows
        guard !rows.isEmpty else { return }
        let current = editor.selection.count == 1 ? editor.selection.first : (delta > 0 ? editor.selection.max() : editor.selection.min())
        let position = current.flatMap { id in rows.firstIndex { $0.id == id } }
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
            if source != nil || translation != nil { project.draftPending = true }
            // SubRip has no field for the character: keep who speaks in the project.
            if let doc = source ?? translation, !doc.storesActorsInFile { project.lineSpeakers = doc.sideSpeakers }
            if let translation, let url = store.translationURL(for: project, language: app.settings.targetLanguage) {
                try translation.write(to: url)
                if project.translationStatus == .new || project.translationStatus == .extracted { project.translationStatus = .reviewed }
            }
            try store.save(project)
        } catch {
            app.report(error, context: "Alterações não salvas")
        }
    }

    /// UI test hooks, inert unless set: `ALS_SELECT=<line>`, `ALS_SEEK=<ms>`, `ALS_TASK=edit|translate`, `ALS_REFERENCE=<id>`,
    /// `ALS_DELETE=<id>`, `ALS_TRACKS=main,reference`, `ALS_TRANSLATE=1`, `ALS_DUB=1|run`.
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
        if let task = env["ALS_TASK"].flatMap(SubtitleTask.init(rawValue:)) {
            chooseSubtitleTask(task)
            if let id = env["ALS_REFERENCE"].flatMap(Int.init) { setReference(id) }
        }
        // ALS_DELETE=<track id>: opens the delete confirmation of the Visão geral.
        if let id = env["ALS_DELETE"].flatMap(Int.init) { trackToDelete = info?.tracks.first { $0.id == id } }
        // ALS_TRACKS=main,reference: what the Legendar bar pickers do.
        if let ids = env["ALS_TRACKS"]?.split(separator: ",").compactMap({ Int($0) }), let main = ids.first {
            Task {
                try? await Task.sleep(for: .seconds(2))
                requestTracks(main: main, reference: ids.count > 1 ? ids[1] : nil)
                try? await Task.sleep(for: .seconds(4))
                if let line = env["ALS_SELECT"].flatMap(Int.init) { editor.selection = [line - 1] }
            }
        }
        if env["ALS_TRANSLATE"] == "1" { translateEpisode(undoManager: nil) }
        if env["ALS_DUB"] == "1" || env["ALS_DUB"] == "run" { startDubSession() }
        if env["ALS_DUB"] == "run" { autoDub(cast: cast, undoManager: nil) }
    }

    func close() {
        editor.flush()
        task?.cancel()
        previewTask?.cancel()
        player.stop()
    }
}
