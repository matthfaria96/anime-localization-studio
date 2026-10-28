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
                var updated = try await workflow.startBlankSubtitle(project, language: language, name: name)
                updated.subtitleTask = .edit
                self.project = updated
                try store.save(updated)
                chooseSubtitleTask(.edit)
                await reload()
                notice = (.info, "Legenda em branco criada. Use + para inserir falas e Salvar › Gravar no vídeo… para gravá-la como faixa nova.")
            } catch {
                app.report(error, context: "A legenda em branco não foi criada")
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
                ? (project.newTrackName ?? project.newTrackLanguage.map(Languages.name(for:)) ?? "Legenda aberta")
                : base.map { "\($0.name ?? $0.codec) · \(Languages.display($0.displayLanguage))" } ?? "Original"
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
            referenceLines = try await workflow().referenceLines(project, track: track)
            editor.reference = referenceLines
            editor.referenceTitle = "\(track.name ?? track.codec) · \(Languages.display(track.displayLanguage))"
        } catch {
            referenceLines = [:]
            notice = (.warning, "A referência não pôde ser carregada: \(LogRedactor.redact(error.localizedDescription))")
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
        panel.message = "Onde salvar a faixa “\(Self.describe(track))”? O arquivo original não é alterado."
        guard panel.runModal() == .OK, let destination = panel.url, claim("Extração de faixa") else { return }
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Extraindo a faixa…")
        let tools = app.tools
        task = Task {
            do {
                let progress: @Sendable (Double) -> Void = { value in Task { @MainActor in self.operation?.fraction = value } }
                let extractor = TrackExtractor(tools: tools)
                let file = track.textSubtitleExtension != nil
                    ? try await extractor.extractSubtitle(track, from: info, to: destination, progress: progress)
                    : try await extractor.extractRaw(track, from: info, to: destination, progress: progress)
                notice = (.success, "Faixa salva em \(file.path).")
                noticeAction = ("Mostrar no Finder", { NSWorkspace.shared.activateFileViewerSelecting([file]) })
            } catch is CancellationError {
                notice = (.info, "Extração cancelada.")
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
        guard !isBusy, editor.source != nil, claim("Salvar a legenda editada") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando…")
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
                    notice = (.success, "Legenda corrigida gravada no próprio arquivo, no lugar da antiga. A versão anterior do arquivo está na Lixeira.")
                } else {
                    notice = (.success, "Novo arquivo com a legenda corrigida: \(output.path). O original não foi alterado.")
                    noticeAction = ("Mostrar no Finder", { NSWorkspace.shared.activateFileViewerSelecting([output]) })
                }
                return
            } catch is CancellationError {
                notice = (.info, "Cancelado. Nenhum arquivo foi criado ou alterado.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }
}
