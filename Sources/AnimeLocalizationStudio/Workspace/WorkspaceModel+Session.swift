import Foundation
import StudioCore
import SubtitleKit

/// Where to go once the question about unsaved subtitle edits is answered.
enum LeaveTarget: Equatable {
    case screen(EpisodeScreen)
    /// Back to the start form of Legendar.
    case chooser
    case close
    case open(URL)
    /// Another subtitle to edit (or another base), and what goes beside it.
    case tracks(main: Int, reference: Int?)

    /// Switching what is edited replaces the draft, so it cannot be kept.
    var keepsDraft: Bool { if case .tracks = self { false } else { true } }
}

/// Legendar keeps every edit as a draft in the app (written as you type). The video changes
/// only with “Gravar no vídeo…”. Leaving after changing something in this visit asks: write
/// it into the video, keep it as a draft, or discard what was changed in this visit.
extension WorkspaceModel {
    enum LeaveChoice { case writeToVideo, keepDraft, discard }

    func beginSubtitleSession() {
        sessionSource = editor.source
        sessionTranslation = editor.translation
        sessionRevision = editor.revision
        sessionDraftPending = project.draftPending ?? false
    }

    /// The subtitle differs from the video (kept in the app, not written into it).
    var hasDraft: Bool { project.draftPending == true || showsUnsavedChanges }

    /// Changed in this visit (cheap check for the screen).
    var showsUnsavedChanges: Bool {
        project.subtitleTask != nil && (editor.revision != sessionRevision || editor.hasPendingDraft)
    }

    /// Exact check before leaving Legendar.
    func hasUnsavedSubtitleChanges(on screen: EpisodeScreen) -> Bool {
        guard screen == .subtitles, project.subtitleTask != nil, editor.hasDocument else { return false }
        editor.flush()
        return editor.source != sessionSource || editor.translation != sessionTranslation
    }

    /// “Voltar”: back to the start form, reloading everything.
    func requestBackToChooser() {
        if hasUnsavedSubtitleChanges(on: .subtitles) { pendingLeave = .chooser } else { perform(.chooser) }
    }

    /// Restores the subtitles as they were when Legendar loaded them.
    func discardSubtitleChanges() {
        editor.flush()
        do {
            if let source = sessionSource, let url = store.sourceSubtitleURL(for: project) { try source.write(to: url) }
            if let url = store.translationURL(for: project, language: app.settings.targetLanguage) {
                if let translation = sessionTranslation {
                    try translation.write(to: url)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            project.draftPending = sessionDraftPending
            if let doc = sessionSource, !doc.storesActorsInFile { project.lineSpeakers = doc.sideSpeakers }
            try store.save(project)
            editor.load(source: sessionSource, translation: sessionTranslation)
            beginSubtitleSession()
        } catch {
            app.report(error, context: "Não foi possível descartar as alterações")
        }
    }

    /// Answers the question asked when leaving with changes.
    func resolveLeave(_ choice: LeaveChoice) {
        guard let target = pendingLeave else { return }
        pendingLeave = nil
        switch choice {
        case .writeToVideo:
            // Stay: the person picks where to write; leaving afterwards no longer asks.
            requestWriteToVideo()
        case .keepDraft:
            editor.flush()
            beginSubtitleSession()
            perform(target)
        case .discard:
            discardSubtitleChanges()
            perform(target)
        }
    }

    func perform(_ target: LeaveTarget) {
        switch target {
        case .screen(let screen): app.showNow(screen)
        case .chooser:
            chooseSubtitleTask(nil)
            Task { await reload() }
        case .close: app.closeVideoNow()
        case .open(let url): app.openNow(url)
        case .tracks(let main, let reference):
            startSubtitleWork(task: project.subtitleTask ?? .edit, trackID: main, referenceID: reference,
                              language: app.settings.targetLanguage, autoTranslate: false)
        }
    }
}
