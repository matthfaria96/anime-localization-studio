import AppKit
import Foundation
import MediaKit
import StudioCore
import SubtitleKit
import UniformTypeIdentifiers

/// What Legendar edits and how it is saved, and the overview's track actions.
extension WorkspaceModel {
    // MARK: What the person is doing in Legendar

    func chooseSubtitleTask(_ task: SubtitleTask?) {
        editor.flush()
        project.subtitleTask = task
        try? store.save(project)
        overlayMode = task == .edit ? .original : .translation
        editor.editsOriginal = task == .edit
        notice = nil
        Task { await loadReference() }
    }

    var isEditingOriginal: Bool { project.subtitleTask == .edit }

    // MARK: Starting Legendar

    /// What is edited (a subtitle, or a translation of it into `language`) and what is beside
    /// it; then loads it all again, and translates when asked.
    func startSubtitleWork(task: SubtitleTask, trackID: Int?, referenceID: Int?, language: String, autoTranslate: Bool,
                           retranslateAll: Bool = false) {
        editor.flush()
        if task == .translate { app.settings.targetLanguage = language }
        if let trackID, trackID != project.sourceTrackID || project.externalSubtitlePath != nil {
            // A translation is matched line by line to its base: it does not carry over to another one.
            if let old = store.translationURL(for: project, language: app.settings.targetLanguage), FileManager.default.fileExists(atPath: old.path) {
                try? store.backupTranslation(of: project, language: app.settings.targetLanguage)
                try? FileManager.default.removeItem(at: old)
            }
            project.sourceTrackID = trackID
            project.externalSubtitlePath = nil
            project.draftPending = false
        }
        project.referenceTrackID = task == .edit ? referenceID : nil
        chooseSubtitleTask(task)
        Task {
            await reload()
            if task == .translate && autoTranslate { translateEpisode(undoManager: nil, retranslateAll: retranslateAll) }
        }
    }

    /// A subtitle written from scratch, alone on the screen, named `name` in the video.
    func startBlankSubtitle(language: String, name: String) {
        guard !isBusy else { return }
        editor.flush()
        let workflow = workflow()
        let project = project
        Task {
            do {
                // The subtitle being edited goes beside the new one (and its timing is offered).
                let beside = project.externalSubtitlePath == nil && project.subtitleTask == .edit ? project.sourceTrackID : project.referenceTrackID
                var updated = try await workflow.startBlankSubtitle(project, language: language, name: name)
                updated.subtitleTask = .edit
                updated.referenceTrackID = beside
                self.project = updated
                try store.save(updated)
                chooseSubtitleTask(.edit)
                await reload()
                notice = (.info, String(localized: "Legenda em branco criada. Use + para inserir falas e Salvar › Gravar no vídeo… para gravá-la como faixa nova."))
            } catch {
                app.report(error, context: String(localized: "A legenda em branco não foi criada"))
            }
        }
    }

    /// A subtitle file from the disk, to correct alone.
    func startImportedSubtitle() {
        project.subtitleTask = .edit
        project.referenceTrackID = nil
        if project.newTrackLanguage == nil { project.newTrackLanguage = app.settings.targetLanguage }
        openExternalSubtitle()
        chooseSubtitleTask(.edit)
    }

    /// A subtitle made from the speech of the video, in the language spoken, at the right times;
    /// then translated into `translateTo` when asked.
    func startFromAudio(spokenLanguage: String, audioTrackID: Int?, identifySpeakers: Bool, translateTo: String?) {
        guard !isBusy else { return }
        editor.flush()
        chooseSubtitleTask(translateTo == nil ? .edit : .translate)
        if let translateTo { app.settings.targetLanguage = translateTo }
        transcribeAudio(language: spokenLanguage, identifySpeakers: identifySpeakers, audioTrackID: audioTrackID) { [weak self] in
            guard let self, translateTo != nil else { return }
            self.translateEpisode(undoManager: nil)
        }
    }

    func setNewTrackLanguage(_ language: String) {
        project.newTrackLanguage = language
        try? store.save(project)
    }

    func setNewTrackName(_ name: String) {
        project.newTrackName = name.isEmpty ? nil : name
        try? store.save(project)
    }

    // MARK: Reference beside the edited subtitle

    func loadReference() async {
        // Translating: beside each line is the subtitle the translation comes from.
        if project.subtitleTask == .translate {
            referenceLines = [:]
            editor.reference = [:]
            let base = subtitleTracks.first { $0.id == project.sourceTrackID }
            editor.referenceTitle = project.externalSubtitlePath != nil
                ? (project.newTrackName ?? project.newTrackLanguage.map(Languages.name(for:)) ?? String(localized: "Legenda aberta"))
                : base.map { "\($0.name ?? $0.codec) · \(Languages.display($0.displayLanguage))" } ?? String(localized: "Original")
            return
        }
        guard project.subtitleTask == .edit, let id = project.referenceTrackID, id != project.sourceTrackID,
              let track = subtitleTracks.first(where: { $0.id == id }) else {
            if project.referenceTrackID != nil && project.referenceTrackID == project.sourceTrackID { project.referenceTrackID = nil }
            referenceLines = [:]
            editor.reference = [:]
            editor.referenceTitle = nil
            return
        }
        do {
            let document = try await workflow().referenceDocument(project, track: track)
            referenceDocument = document
            referenceLines = editor.source.map { TranslationAlignment.reference(document, for: $0) } ?? [:]
            editor.reference = referenceLines
            editor.referenceTitle = "\(track.name ?? track.codec) · \(Languages.display(track.displayLanguage))"
            // An empty subtitle beside one with other timings: ask whether to write over that timing.
            if let source = editor.source, source.isBlank, document.differsInTiming(from: source) { pendingTimingOffer = track }
        } catch {
            referenceLines = [:]
            notice = (.warning, String(localized: "A referência não pôde ser carregada: \(LogRedactor.redact(error.localizedDescription))"))
        }
    }

    /// Changes what is edited and what is beside it, from the Legendar bar. Changing only the
    /// subtitle beside never loses anything; another edited subtitle replaces the current one,
    /// so with unsaved changes it asks first (save, discard or keep editing).
    func requestTracks(main: Int, reference: Int?) {
        let reference = reference == main ? nil : reference
        // -2 is the subtitle open now (new or imported); -3 the translation being edited.
        let isCurrent = main == -3 || main == -2 || (isEditingOriginal && main == project.sourceTrackID && project.externalSubtitlePath == nil)
        if isCurrent {
            if isEditingOriginal { setReference(reference) }
            return
        }
        requestNewSubtitle(.tracks(main: main, reference: reference))
    }

    /// ⇄: the subtitle beside becomes the one edited, and the other way around.
    func swapEditedAndReference() {
        guard let reference = project.referenceTrackID, let main = project.sourceTrackID else { return }
        requestTracks(main: reference, reference: main)
    }

    /// “Sim”: the empty subtitle gets the lines of the one beside, same times, styles,
    /// characters and places on screen, with no text (⌘Z undoes).
    func useReferenceTiming() {
        pendingTimingOffer = nil
        guard let document = referenceDocument else { return }
        let video = info?.tracks(.video).first
        let copy = document.timingCopy(playResX: video?.width ?? 1920, playResY: video?.height ?? 1080)
        editor.replaceSource(copy, undoManager: editor.undoManager)
        project.sourceFormat = copy.format
        editor.flush()
        referenceLines = TranslationAlignment.reference(document, for: copy)
        editor.reference = referenceLines
        notice = (.success, String(localized: "\(Plural.count(copy.count, "fala criada", "falas criadas")) com os tempos da legenda ao lado, em branco para você escrever."))
    }

    /// “Não”: nothing beside.
    func declineReferenceTiming() {
        pendingTimingOffer = nil
        setReference(nil)
    }

    func setReference(_ id: Int?) {
        project.referenceTrackID = id
        try? store.save(project)
        Task { await loadReference() }
    }

    /// Salvar › Gravar no vídeo…: the window with the track name and where to write.
    func requestWriteToVideo() {
        guard !isBusy, editor.hasDocument, isEditingOriginal || editor.translation != nil else { return }
        editor.flush()
        showWriteSheet = true
    }

    /// Writes what is edited into the video: a corrected track in place of the old one, or a
    /// new subtitle (translation, blank, imported or from the audio) as a new track.
    func writeToVideo(replaceOriginal: Bool) {
        if isEditingOriginal { saveEditedSubtitle(replaceOriginal: replaceOriginal) } else { embedTranslation(replaceOriginal: replaceOriginal) }
    }

    // MARK: Extracting a track

    /// Saves one track as its own file (subtitles keep their ASS header; audio and video are
    /// copied as they are, never converted).
    func extractTrack(_ track: MediaTrack) {
        guard let info, !isBusy else { return }
        let ext = track.nativeFileExtension
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "\(title).\(track.id).\(track.displayLanguage).\(ext)"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = String(localized: "Onde salvar a faixa “\(Self.describe(track))”? O arquivo original não é alterado.")
        guard panel.runModal() == .OK, let destination = panel.url, claim(String(localized: "Extração de faixa")) else { return }
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: String(localized: "Extraindo a faixa…"))
        let tools = app.tools
        task = Task {
            do {
                let progress: @Sendable (Double) -> Void = { value in Task { @MainActor in self.operation?.fraction = value } }
                let extractor = TrackExtractor(tools: tools)
                let file = track.textSubtitleExtension != nil
                    ? try await extractor.extractSubtitle(track, from: info, to: destination, progress: progress)
                    : try await extractor.extractRaw(track, from: info, to: destination, progress: progress)
                notice = (.success, String(localized: "Faixa salva em \(file.path)."))
                noticeAction = (String(localized: "Mostrar no Finder"), { NSWorkspace.shared.activateFileViewerSelecting([file]) })
            } catch is CancellationError {
                notice = (.info, String(localized: "Extração cancelada."))
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    // MARK: Saving an edited subtitle

    /// Puts the corrected subtitle in the MKV in place of the track it came from.
    func saveEditedSubtitle(replaceOriginal: Bool) {
        guard !isBusy, editor.source != nil, claim(String(localized: "Salvar a legenda editada")) else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: String(localized: "Preparando…"))
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, output, report) = try await workflow.saveEditedSubtitle(project, replaceOriginal: replaceOriginal) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                self.project.draftPending = false
                try? store.save(self.project)
                release()
                operation = nil
                if replaceOriginal {
                    await reload()
                    notice = (.success, String(localized: "Legenda corrigida gravada no próprio arquivo, no lugar da antiga. A versão anterior do arquivo está na Lixeira."))
                } else {
                    notice = (.success, String(localized: "Novo arquivo com a legenda corrigida: \(output.path). O original não foi alterado."))
                    noticeAction = (String(localized: "Mostrar no Finder"), { NSWorkspace.shared.activateFileViewerSelecting([output]) })
                }
                return
            } catch is CancellationError {
                notice = (.info, String(localized: "Cancelado. Nenhum arquivo foi criado ou alterado."))
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }
}
