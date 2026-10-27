import Foundation
import StudioCore
import SubtitleKit

/// Where to go once the question about unsaved subtitle edits is answered.
enum LeaveTarget: Equatable {
    case screen(EpisodeScreen)
    /// Back to the “edit or translate?” choice.
    case chooser
    case close
    case open(URL)
}

/// Legendar keeps edits on disk as you type, but treats each visit as a session: leaving it
/// with changes asks whether to keep them or go back to how the subtitles were when loaded.
extension WorkspaceModel {
    func beginSubtitleSession() {
        sessionSource = editor.source
        sessionTranslation = editor.translation
        sessionRevision = editor.revision
    }

    /// Cheap check for the screen (edits not yet committed from the text fields count too).
    var showsUnsavedChanges: Bool {
        project.subtitleTask != nil && (editor.revision != sessionRevision || editor.hasPendingDraft)
    }

    /// Exact check before leaving Legendar.
    func hasUnsavedSubtitleChanges(on screen: EpisodeScreen) -> Bool {
        guard screen == .subtitles, project.subtitleTask != nil, editor.hasDocument else { return false }
        editor.flush()
        return editor.source != sessionSource || editor.translation != sessionTranslation
    }

    /// “Voltar”: back to the choice of task, reloading everything.
    func requestBackToChooser() {
        if hasUnsavedSubtitleChanges(on: .subtitles) { pendingLeave = .chooser } else { perform(.chooser) }
    }

    /// Keeps the changes as the new starting point.
    func saveSubtitleSession() {
        editor.flush()
        beginSubtitleSession()
        notice = (.success, "Alterações salvas no projeto. Para gravá-las no vídeo, use “\(isEditingOriginal ? "Salvar no MKV…" : "Incorporar ao MKV…")”.")
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
            editor.load(source: sessionSource, translation: sessionTranslation)
            beginSubtitleSession()
        } catch {
            app.report(error, context: "Não foi possível descartar as alterações")
        }
    }

    /// Answers the unsaved-changes question, then goes where the person asked.
    func resolveLeave(save: Bool) {
        guard let target = pendingLeave else { return }
        pendingLeave = nil
        if save { saveSubtitleSession() } else { discardSubtitleChanges() }
        perform(target)
    }

    func perform(_ target: LeaveTarget) {
        switch target {
        case .screen(let screen): app.showNow(screen)
        case .chooser:
            chooseSubtitleTask(nil)
            Task { await reload() }
        case .close: app.closeVideoNow()
        case .open(let url): app.openNow(url)
        }
    }
}
