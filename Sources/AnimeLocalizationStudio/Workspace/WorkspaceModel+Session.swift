import AppKit
import Foundation
import StudioCore
import SubtitleKit

/// Where to go once the question about unsaved subtitle changes is answered.
enum LeaveTarget: Equatable {
    case screen(EpisodeScreen)
    case close
    case open(URL)
    case quit
    /// Another subtitle to edit, and what goes beside it.
    case tracks(main: Int, reference: Int?)
    /// A new subtitle in place of the current one.
    case blank(language: String, name: String)
    case importFile
    case translate(TranslationRequest)
}

/// What the Traduzir window asked for.
struct TranslationRequest: Equatable {
    enum Source: Equatable {
        /// A text subtitle of the video (track id), or -2 for the subtitle open now (new or imported).
        case subtitle(Int)
        /// The speech of an audio track, in the language spoken.
        case audio(track: Int?, spokenLanguage: String, identifySpeakers: Bool)
    }

    var source: Source
    var language: String
    /// Translate every line again, replacing a translation already made into that language.
    var retranslateAll = false
}

/// Legendar edits one subtitle at a time. Edits are kept in the app as they are typed (so a
/// crash loses nothing), but they only count as saved once written into the video or exported.
/// Leaving with unsaved changes asks: save (into the video or as a file), discard, or keep editing.
extension WorkspaceModel {
    enum LeaveChoice { case writeToVideo, export, discard }

    /// The subtitle has changes that are neither in the video nor exported.
    func hasUnsavedSubtitleChanges(on screen: EpisodeScreen) -> Bool {
        guard screen == .subtitles, editor.hasDocument else { return false }
        editor.flush()
        return project.draftPending == true
    }

    /// A new subtitle (blank or imported) in place of the current one; asks first when the
    /// current one has unsaved changes.
    func requestNewSubtitle(_ target: LeaveTarget) {
        if hasUnsavedSubtitleChanges(on: .subtitles) { pendingLeave = target } else { perform(target) }
    }

    /// A translation replaces what is edited, so unsaved changes are asked about first.
    func requestTranslation(_ request: TranslationRequest) {
        requestNewSubtitle(.translate(request))
    }

    /// Everything not written into the video goes: corrections, a new or imported subtitle and
    /// the translation (a backup copy of it stays in the project). The subtitle is the video's again.
    func discardUnsavedChanges() {
        editor.flush()
        let files = FileManager.default
        if let url = store.translationURL(for: project, language: app.settings.targetLanguage), files.fileExists(atPath: url.path) {
            try? store.backupTranslation(of: project, language: app.settings.targetLanguage)
            try? files.removeItem(at: url)
            project.autoSpeakers?["translation"] = nil
        }
        if let url = store.sourceSubtitleURL(for: project) { try? files.removeItem(at: url) }
        project.externalSubtitlePath = nil
        project.newTrackName = nil
        project.newTrackLanguage = nil
        project.draftPending = false
        chooseSubtitleTask(.edit)
        notice = nil
    }

    /// Answers the question asked when leaving with changes.
    func resolveLeave(_ choice: LeaveChoice) {
        guard let target = pendingLeave else { return }
        pendingLeave = nil
        switch choice {
        case .writeToVideo:
            // Stay: the person picks where to write; leaving afterwards no longer asks.
            requestWriteToVideo()
        case .export:
            if exportCurrent() { perform(target) }
        case .discard:
            discardUnsavedChanges()
            perform(target)
        }
    }

    func perform(_ target: LeaveTarget) {
        switch target {
        case .screen(let screen): app.showNow(screen)
        case .close: app.closeVideoNow()
        case .open(let url): app.openNow(url)
        case .quit: app.quitNow()
        case .blank(let language, let name): startBlankSubtitle(language: language, name: name)
        case .importFile: startImportedSubtitle()
        case .translate(let request): startTranslation(request)
        case .tracks(let main, let reference):
            startSubtitleWork(task: .edit, trackID: main, referenceID: reference, language: app.settings.targetLanguage, autoTranslate: false)
        }
    }

    /// Runs what the Traduzir window asked for: a subtitle of the video translated into
    /// `language`, or the speech of the video written down and, in another language, translated.
    func startTranslation(_ request: TranslationRequest) {
        switch request.source {
        case .subtitle(let id):
            startSubtitleWork(task: .translate, trackID: id < 0 ? nil : id, referenceID: nil, language: request.language,
                              autoTranslate: true, retranslateAll: request.retranslateAll)
        case .audio(let track, let spoken, let identify):
            let same = Languages.base(spoken) == Languages.base(request.language)
            startFromAudio(spokenLanguage: spoken, audioTrackID: track, identifySpeakers: identify, translateTo: same ? nil : request.language)
        }
    }

    /// Saves the subtitle being edited as a file of its own. Counts as saved: leaving no longer asks.
    @discardableResult
    func exportCurrent() -> Bool {
        editor.flush()
        let document = isEditingOriginal ? editor.source : editor.translation
        guard let document, let format = project.sourceFormat else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: format.fileExtension) ?? .plainText]
        let language = isEditingOriginal ? project.newTrackLanguage.map { ".\($0)" } ?? "" : ".\(app.settings.targetLanguage)"
        panel.nameFieldStringValue = "\(project.title)\(language).\(format.fileExtension)"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            try document.write(to: destination)
            project.draftPending = false
            try? store.save(project)
            notice = (.success, String(localized: "Legenda salva em \(destination.path)."))
            noticeAction = (String(localized: "Mostrar no Finder"), { NSWorkspace.shared.activateFileViewerSelecting([destination]) })
            return true
        } catch {
            app.report(error, context: String(localized: "A legenda não foi salva"))
            return false
        }
    }
}
