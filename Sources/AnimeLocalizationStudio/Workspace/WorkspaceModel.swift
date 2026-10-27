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
    @ObservationIgnored private var task: Task<Void, Never>?
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
            Task { await loadEmbeddedFonts(info) }
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
            // A file muxed before already carries the translation as a track: use it.
            if editor.translation == nil, let info, let existing = workflow().existingTranslationTrack(in: info, project: project),
               let (linked, result) = try? await workflow().linkTranslation(project, track: existing) {
                project = linked
                editor.load(source: source, translation: result.document)
                notice = (.info, "A faixa “\(existing.name ?? existing.displayLanguage)” do arquivo foi carregada como tradução. Troque em Tradução, no inspetor.")
            }
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

    func chooseDefault(_ track: MediaTrack) {
        var defaults = effectiveDefaults
        switch track.kind {
        case .audio: defaults.audioTrackID = track.id
        case .subtitles: defaults.subtitleTrackID = defaults.subtitleTrackID == track.id ? -1 : track.id
        default: return
        }
        pendingDefaults = defaults
    }

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

    /// Asks where to write before muxing.
    func requestEmbed() {
        guard !isBusy, editor.translation != nil else { return }
        askEmbedDestination = true
    }

    func embedTranslation(replaceOriginal: Bool = false) {
        guard !isBusy, editor.translation != nil, claim("Incorporação no estúdio") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando incorporação…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, output, report) = try await workflow.mux(project, replaceOriginal: replaceOriginal) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                lastMux = (output, report)
                if replaceOriginal {
                    release()
                    operation = nil
                    await reload()
                    notice = (.success, "Faixa incorporada no próprio arquivo e verificada. A versão anterior está na Lixeira.")
                    return
                }
                notice = (.success, "Novo arquivo criado e verificado: \(output.lastPathComponent). O original não foi alterado.")
                noticeAction = ("Abrir o novo arquivo", { [app] in app.open(output) })
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
    /// Set when the speaker-identification models must be downloaded first: the action to retry.
    var pendingDiarizationDownload: (() -> Void)?

    var speakerModelsInstalled: Bool { SpeakerDiarization(modelsDirectory: app.paths.diarizationModels).modelsInstalled }

    func transcribeAudio(language: String, allowModelDownload: Bool = false, identifySpeakers: Bool = false, allowDiarizationDownload: Bool = false) {
        guard !isBusy, claim("Transcrição no estúdio") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Preparando transcrição…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let updated = try await workflow.transcribe(project, language: language, allowModelDownload: allowModelDownload,
                                                            identifySpeakers: identifySpeakers, allowDiarizationDownload: allowDiarizationDownload) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                if let old = store.translationURL(for: updated, language: app.settings.targetLanguage) { try? FileManager.default.removeItem(at: old) }
                operation = nil
                release()
                await loadSubtitles()
                notice = (.success, identifySpeakers
                          ? "Transcrição pronta: \(editor.rows.count) falas de \(Set(editor.rows.map(\.actor)).filter { !$0.isEmpty }.count) falantes. Renomeie os falantes na aba Dublagem."
                          : "Transcrição pronta: \(editor.rows.count) falas. Revise e traduza.")
                return
            } catch SpeechTranscription.TranscriptionError.modelDownloadRequired(let language) {
                pendingModelDownload = language
            } catch SpeakerDiarization.DiarizationError.modelsNotInstalled {
                // Cleared when the consent dialog is answered or dismissed.
                pendingDiarizationDownload = {
                    self.transcribeAudio(language: language, allowModelDownload: allowModelDownload, identifySpeakers: true, allowDiarizationDownload: true)
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

    /// Fills the character field of the spoken lines from the audio, keeping characters that
    /// are already set unless `replaceExisting`.
    func identifySpeakers(allowModelDownload: Bool = false, replaceExisting: Bool = false, undoManager: UndoManager?) {
        guard !isBusy, let document = editor.translation ?? editor.source, claim("Identificação de falantes") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Preparando a identificação de falantes…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                var speakers = try await workflow.identifySpeakers(in: document, of: project, allowModelDownload: allowModelDownload) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                if !replaceExisting {
                    let named = Set(editor.rows.filter { !$0.actor.isEmpty }.map(\.id))
                    speakers = speakers.filter { !named.contains($0.key) }
                }
                editor.setActors(speakers, undoManager: undoManager)
                editor.flush()
                let count = Set(speakers.values).count
                notice = speakers.isEmpty
                    ? (.info, "Nenhuma fala sem personagem para identificar.")
                    : (.success, "\(speakers.count) falas atribuídas a \(count) falantes. Renomeie cada falante com o nome do personagem (⌘Z desfaz).")
            } catch SpeakerDiarization.DiarizationError.modelsNotInstalled {
                pendingDiarizationDownload = {
                    self.identifySpeakers(allowModelDownload: true, replaceExisting: replaceExisting, undoManager: undoManager)
                }
            } catch is CancellationError {
                notice = (.info, "Identificação de falantes cancelada.")
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

    // MARK: Automatic dub with the original voices

    /// Clips of each speaker's original voice, for “Ouvir original”.
    var voiceSamples: [String: URL] = [:]

    func prepareVoiceSamples() async {
        guard voiceSamples.isEmpty, claim("Amostras das vozes originais") else { return }
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Separando as vozes originais…")
        defer { release(); operation = nil }
        do {
            let samples = try await workflow().voiceSamples(project) { step in
                Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
            }
            voiceSamples = Dictionary(samples.map { ($0.speaker, $0.url) }, uniquingKeysWith: { a, _ in a })
        } catch {
            notice = (.error, LogRedactor.redact(error.localizedDescription))
        }
    }

    /// The guided dub window: confirm → running (with steps) → done or failed.
    struct DubSession {
        enum Phase {
            case confirm
            case running
            case done(url: URL, report: DubbingReport, verification: VerificationReport, replaced: Bool)
            case failed(String)
        }
        var phase: Phase = .confirm
        var replaceOriginal = false
    }

    enum DubStage: Int, CaseIterable {
        case speakers, voices, speech, mix, file

        var title: String {
            switch self {
            case .speakers: "Identificar quem fala"
            case .voices: "Preparar a voz de cada personagem"
            case .speech: "Gerar as falas em português"
            case .mix: "Mixar com a música e os efeitos"
            case .file: "Gravar e verificar o MKV"
            }
        }

        /// Where each stage sits in the overall progress of `autoDub`.
        static func at(_ fraction: Double) -> DubStage {
            switch fraction {
            case ..<0.2: .speakers
            case ..<0.4: .voices
            case ..<0.85: .speech
            case ..<0.94: .mix
            default: .file
            }
        }
    }

    var dubSession: DubSession?

    func startDubSession() {
        guard !isBusy, editor.translation != nil else { return }
        dubSession = DubSession()
    }

    /// Identifies who speaks (when the subtitle does not say), gives each character a voice (a
    /// clone of the original, or a similar macOS voice), dubs every line and writes the MKV.
    func autoDub(cast: VoiceCast, allowDiarizationDownload: Bool = false, undoManager: UndoManager?, onCast: @escaping (VoiceCast) -> Void) {
        guard !isBusy, editor.translation != nil, claim("Dublagem automática") else { return }
        let replaceOriginal = dubSession?.replaceOriginal ?? false
        dubSession?.phase = .running
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando a dublagem…")
        let workflow = workflow()
        let systemVoices = Set(AVSpeechSynthesisVoice.speechVoices().map(\.name))
        let engine = app.settings.dubbingEngine.label, mode = app.settings.dubbingMode.label
        AppLog.shared.info("Dublagem iniciada: \(project.title) · \(engine) · \(mode) · \(replaceOriginal ? "no próprio arquivo" : "novo arquivo")")
        task = Task {
            do {
                var project = project
                if let document = editor.translation, DubbingPlan.segments(from: document).allSatisfy({ $0.speaker == "Desconhecido" }) {
                    let speakers = try await workflow.identifySpeakers(in: document, of: project, allowModelDownload: allowDiarizationDownload) { step in
                        Task { @MainActor in self.operation?.fraction = step.fraction * 0.2; self.operation?.message = step.message }
                    }
                    editor.setActors(speakers, undoManager: undoManager)
                    editor.flush()
                }
                let filled = try await workflow.automaticCast(project, cast: cast, systemVoices: systemVoices) { step in
                    Task { @MainActor in self.operation?.fraction = 0.2 + step.fraction * 0.2; self.operation?.message = step.message }
                }
                onCast(filled)
                saveCast(filled)
                let synthesizer = app.settings.makeSynthesizer()
                let (updated, output, report, verification) = try await workflow.dub(project, synthesizer: synthesizer, cast: filled,
                                                                                    replaceOriginal: replaceOriginal) { step in
                    Task { @MainActor in self.operation?.fraction = 0.4 + step.fraction * 0.6; self.operation?.message = step.message }
                }
                project = updated
                self.project = updated
                lastDub = (output, report, verification)
                lastMux = (output, verification)
                dubSession?.phase = .done(url: output, report: report, verification: verification, replaced: replaceOriginal)
                AppLog.shared.info("Dublagem concluída: \(output.path)")
                release()
                operation = nil
                if replaceOriginal { await reload() }
                return
            } catch SpeakerDiarization.DiarizationError.modelsNotInstalled {
                dubSession?.phase = .confirm
                pendingDiarizationDownload = { self.autoDub(cast: cast, allowDiarizationDownload: true, undoManager: undoManager, onCast: onCast) }
            } catch is CancellationError {
                dubSession?.phase = .failed("Dublagem cancelada. As falas já geradas ficam guardadas e serão reaproveitadas na próxima vez. Nenhum arquivo foi criado ou alterado.")
            } catch {
                let message = Self.explainDubError(error)
                AppLog.shared.error("Dublagem falhou: \(message)")
                dubSession?.phase = .failed(message)
            }
            release()
            operation = nil
        }
    }

    /// Turns technical failures into what happened and what to do.
    static func explainDubError(_ error: Error) -> String {
        if case VoiceStudioClient.ClientError.notRunning = error {
            return "O VoiceStudio não está aberto, então as vozes originais não puderam ser clonadas. Abra o VoiceStudio e tente de novo, ou escolha “Vozes do macOS”. Nenhum arquivo foi criado ou alterado."
        }
        if case SynthesisError.engineUnavailable = error {
            return "O motor de voz parou de responder no meio da dublagem. Nenhum arquivo foi criado ou alterado; as falas já geradas serão reaproveitadas."
        }
        return LogRedactor.redact(error.localizedDescription) + " Nenhum arquivo foi criado ou alterado."
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

    /// UI test hooks, inert unless set: `ALS_SELECT=<line>`, `ALS_SEEK=<ms>`, `ALS_TRANSLATE=1`, `ALS_DUB=1`, `ALS_IDENTIFY=1`.
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
        if env["ALS_DUB"] == "1" || env["ALS_DUB"] == "run" { startDubSession() }
        if env["ALS_DUB"] == "run" { autoDub(cast: loadCast(), undoManager: nil) { [weak self] in self?.saveCast($0) } }
        if env["ALS_IDENTIFY"] == "1" { identifySpeakers(undoManager: nil) }
    }

    func close() {
        editor.flush()
        task?.cancel()
        previewTask?.cancel()
        player.stop()
    }
}
