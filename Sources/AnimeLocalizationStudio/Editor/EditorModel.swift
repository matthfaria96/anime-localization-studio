import AppKit
import Foundation
import Observation
import SubtitleKit

enum DocumentSide: String, CaseIterable, Identifiable {
    case original, translation
    var id: String { rawValue }
    var label: String { self == .original ? "Original" : "Tradução" }
}

enum LineFilter: String, CaseIterable, Identifiable {
    case all, untranslated, skipped, longLines, spelling
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "Todas as falas"
        case .untranslated: "Sem tradução"
        case .skipped: "Não traduzíveis"
        case .longLines: "Leitura rápida demais"
        case .spelling: "Possíveis erros de ortografia"
        }
    }
}

struct EditorRow: Identifiable, Hashable {
    let id: Int
    let start: Int
    let end: Int
    let style: String
    let actor: String
    let original: String
    let translation: String
    let isComment: Bool
    let skipReason: TranslationSkipReason?
    let isTranslated: Bool
    /// Characters per second of the visible translation (fansub guides aim for ≤ 17–20).
    let readingSpeed: Double
}

/// The two working documents (original and translation) and every edit made to them.
/// Both documents always keep the same lines and timing; only text differs.
@Observable
final class EditorModel {
    private(set) var source: SubtitleDocument?
    private(set) var translation: SubtitleDocument?
    private(set) var rows: [EditorRow] = []
    /// Increases on every document change (cheap to observe, unlike `rows`).
    private(set) var revision = 0
    private var sourceCues: [SubtitleCue] = []
    private var translationCues: [SubtitleCue] = []

    var selection: Set<Int> = []
    var filter: LineFilter = .all
    var searchQuery = ""
    var replacement = ""
    var caseSensitive = false
    var searchSide: DocumentSide = .translation
    var followPlayback = true
    private(set) var isDirty = false

    /// Text being typed for the selected line, not applied yet. Kept here (not in the view) so
    /// `flush()` applies it before muxing, translating, exporting or closing.
    var originalDraft = ""
    var translationDraft = ""
    private(set) var draftIndex: Int?
    @ObservationIgnored private var committedOriginal = ""
    @ObservationIgnored private var committedTranslation = ""
    /// The window's undo manager, set by the editor views.
    @ObservationIgnored weak var undoManager: UndoManager?

    /// Called (debounced) after edits so the workspace writes the working files.
    @ObservationIgnored var onChange: ((SubtitleDocument?, SubtitleDocument?) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var hasDocument: Bool { source != nil }
    var styleNames: [String] {
        guard case .ass(let doc) = source else { return [] }
        return doc.styles.compactMap { $0["Name"]?.trimmingCharacters(in: .whitespaces) }
    }

    func load(source: SubtitleDocument?, translation: SubtitleDocument?) {
        // Undo steps hold the previous documents; replaying them after a reload would write
        // another track's text into this track's working files.
        undoManager?.removeAllActions(withTarget: self)
        draftIndex = nil
        self.source = source
        self.translation = translation
        selection = []
        isDirty = false
        refresh()
    }

    var visibleRows: [EditorRow] {
        let filtered: [EditorRow] = switch filter {
        case .all: rows
        case .untranslated: rows.filter { $0.skipReason == nil && !$0.isTranslated }
        case .skipped: rows.filter { $0.skipReason != nil }
        case .longLines: rows.filter { $0.readingSpeed > maxReadingSpeed }
        case .spelling: rows.filter { $0.isTranslated && Self.misspelledWords(in: $0.translation, language: spellingLanguage) > 0 }
        }
        guard !searchQuery.isEmpty else { return filtered }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        return filtered.filter { ($0.original + "\n" + $0.translation + "\n" + $0.actor).range(of: searchQuery, options: options) != nil }
    }

    var translatedCount: Int { rows.filter(\.isTranslated).count }
    var translatableCount: Int { rows.filter { $0.skipReason == nil }.count }

    /// Characters per second above which a line reads too fast (Ajustes › Geral).
    var maxReadingSpeed = 20.0

    /// Language for the spelling filter (`pt_BR` style, as NSSpellChecker names them).
    var spellingLanguage = "pt_BR"

    static func misspelledWords(in text: String, language: String) -> Int {
        let checker = NSSpellChecker.shared
        var count = 0
        var start = 0
        let string = text as NSString
        while start < string.length {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            count += 1
            start = range.location + range.length
        }
        return count
    }

    func activeCues(at time: Int, in side: DocumentSide) -> [SubtitleCue] {
        let cues = side == .translation && translation != nil ? translationCues : sourceCues
        return cues.filter { !$0.isComment && !$0.features.hasDrawing && $0.start <= time && time < $0.end }
            .sorted { $0.layer < $1.layer }
    }

    func cue(_ id: Int, side: DocumentSide) -> SubtitleCue? {
        let cues = side == .translation ? translationCues : sourceCues
        return cues.indices.contains(id) ? cues[id] : nil
    }

    func line(at time: Int) -> Int? {
        rows.last { !$0.isComment && $0.start <= time && time < $0.end }?.id
    }

    // MARK: Edits (all undoable)

    func setText(_ raw: String, side: DocumentSide, index: Int, undoManager: UndoManager?) {
        if side == .translation && translation == nil { translation = source }
        guard raw != displayRaw(side, index) else { return }
        mutate("Editar fala", undoManager: undoManager) { source, translation in
            if side == .original { source?.setRawText(raw, at: index) } else { translation?.setRawText(raw, at: index) }
        }
    }

    func setTiming(start: Int, end: Int, index: Int, undoManager: UndoManager?) {
        mutate("Alterar tempo", undoManager: undoManager) { source, translation in
            source?.setTiming(start: start, end: end, at: index)
            translation?.setTiming(start: start, end: end, at: index)
        }
    }

    func setActor(_ actor: String, index: Int, undoManager: UndoManager?) {
        mutate("Alterar personagem", undoManager: undoManager) { source, translation in
            source?.setActor(actor, at: index)
            translation?.setActor(actor, at: index)
        }
    }

    /// Sets the character of many lines at once (speaker identification), in both documents.
    func setActors(_ actors: [Int: String], undoManager: UndoManager?) {
        guard !actors.isEmpty else { return }
        mutate("Identificar falantes", undoManager: undoManager) { source, translation in
            for (index, actor) in actors {
                source?.setActor(actor, at: index)
                translation?.setActor(actor, at: index)
            }
        }
    }

    /// Renames a character in every line ("Falante 1" → "Kirito").
    func renameActor(_ old: String, to new: String, undoManager: UndoManager?) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        let indices = rows.filter { $0.actor == old }.map(\.id)
        mutate("Renomear personagem", undoManager: undoManager) { source, translation in
            for index in indices {
                source?.setActor(name, at: index)
                translation?.setActor(name, at: index)
            }
        }
    }

    func setStyle(_ style: String, index: Int, undoManager: UndoManager?) {
        mutate("Alterar estilo", undoManager: undoManager) { source, translation in
            source?.setStyle(style, at: index)
            translation?.setStyle(style, at: index)
        }
    }

    /// Adds an empty line after `index` in both documents and selects it.
    func insertLine(after index: Int, undoManager: UndoManager?) {
        var newIndex = index + 1
        mutate("Inserir fala", undoManager: undoManager) { source, translation in
            newIndex = source?.insertLine(after: index) ?? newIndex
            translation?.insertLine(after: index)
        }
        selection = [newIndex]
    }

    func removeLines(_ indices: Set<Int>, undoManager: UndoManager?) {
        guard !indices.isEmpty else { return }
        draftIndex = nil
        mutate(indices.count == 1 ? "Excluir fala" : "Excluir falas", undoManager: undoManager) { source, translation in
            for index in indices.sorted(by: >) {
                source?.removeLine(at: index)
                translation?.removeLine(at: index)
            }
        }
        selection = []
    }

    func shift(by offset: Int, onlySelection: Bool, undoManager: UndoManager?) {
        let indices = onlySelection ? selection : nil
        mutate("Deslocar tempos", undoManager: undoManager) { source, translation in
            source?.shift(by: offset, indices: indices)
            translation?.shift(by: offset, indices: indices)
        }
    }

    @discardableResult
    func replaceAll(undoManager: UndoManager?) -> Int {
        guard !searchQuery.isEmpty else { return 0 }
        var changed = 0
        let (query, replacement, caseSensitive, side) = (searchQuery, replacement, caseSensitive, searchSide)
        mutate("Substituir tudo", undoManager: undoManager) { source, translation in
            if side == .original {
                changed = source?.replace(query, with: replacement, caseSensitive: caseSensitive) ?? 0
            } else {
                if translation == nil { translation = source }
                changed = translation?.replace(query, with: replacement, caseSensitive: caseSensitive) ?? 0
            }
        }
        return changed
    }

    func updateStyle(_ info: ASSStyleInfo, at styleIndex: Int, undoManager: UndoManager?) {
        mutate("Editar estilo", undoManager: undoManager) { source, translation in
            if case .ass(var doc) = source { doc.updateStyle(at: styleIndex) { info.apply(to: &$0) }; source = .ass(doc) }
            if case .ass(var doc) = translation { doc.updateStyle(at: styleIndex) { info.apply(to: &$0) }; translation = .ass(doc) }
        }
    }

    /// Replaces the whole translation (after “Traduzir episódio inteiro”), undoably.
    func applyTranslation(_ document: SubtitleDocument, undoManager: UndoManager?) {
        mutate("Traduzir episódio", undoManager: undoManager) { _, translation in translation = document }
    }

    func startManualTranslation() {
        guard translation == nil else { return }
        translation = source
        refresh()
        scheduleSave()
    }

    private func mutate(_ name: String, undoManager: UndoManager?, _ change: (inout SubtitleDocument?, inout SubtitleDocument?) -> Void) {
        let before = (source, translation)
        var newSource = source
        var newTranslation = translation
        change(&newSource, &newTranslation)
        guard newSource != before.0 || newTranslation != before.1 else { return }
        source = newSource
        translation = newTranslation
        registerUndo(restoring: before, name: name, undoManager: undoManager)
        refresh()
        scheduleSave()
    }

    private func registerUndo(restoring state: (SubtitleDocument?, SubtitleDocument?), name: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        self.undoManager = undoManager
        undoManager.registerUndo(withTarget: self) { model in
            let current = (model.source, model.translation)
            model.source = state.0
            model.translation = state.1
            model.registerUndo(restoring: current, name: name, undoManager: undoManager)
            model.refresh()
            model.scheduleSave()
        }
        undoManager.setActionName(name)
    }

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            self.flush()
        }
    }

    // MARK: Drafts

    var hasPendingDraft: Bool {
        draftIndex != nil && (originalDraft != committedOriginal || translationDraft != committedTranslation)
    }

    /// Applies the drafts of the line being edited and starts editing `index`.
    func beginEditing(_ index: Int?) {
        commitDrafts()
        draftIndex = index
        reloadDrafts(force: true)
    }

    func commitDrafts() {
        guard let index = draftIndex, let source, index < source.count else { return }
        let (original, translated) = (originalDraft, translationDraft)
        if original != committedOriginal { setText(original, side: .original, index: index, undoManager: undoManager) }
        if translated != committedTranslation { setText(translated, side: .translation, index: index, undoManager: undoManager) }
    }

    func displayRaw(_ side: DocumentSide, _ index: Int) -> String {
        let document = side == .original ? source : (translation ?? source)
        guard let document, index < document.count else { return "" }
        let raw = document.rawText(at: index)
        return document.usesHTMLMarkup ? raw : raw.replacingOccurrences(of: "\\N", with: "\n")
    }

    /// After a document change, refresh drafts the person has not touched; keep the ones they did.
    private func reloadDrafts(force: Bool) {
        guard let index = draftIndex else { return }
        let original = displayRaw(.original, index)
        let translated = displayRaw(.translation, index)
        if force || originalDraft == committedOriginal { originalDraft = original }
        if force || translationDraft == committedTranslation { translationDraft = translated }
        committedOriginal = original
        committedTranslation = translated
    }

    /// Writes pending edits now (before muxing, closing or quitting).
    func flush() {
        commitDrafts()
        saveTask?.cancel()
        guard isDirty else { return }
        onChange?(source, translation)
        isDirty = false
    }

    private func refresh() {
        defer { reloadDrafts(force: false); revision += 1 }
        sourceCues = source?.cues ?? []
        translationCues = translation?.cues ?? []
        guard let source else { rows = []; return }
        rows = sourceCues.map { cue in
            let translated = translationCues.indices.contains(cue.id) ? translationCues[cue.id] : nil
            let translatedText = translated?.plainText ?? ""
            let isTranslated = translated.map { $0.rawText != cue.rawText } ?? false
            let seconds = max(0.001, Double(cue.duration) / 1_000)
            let visible = (isTranslated ? translatedText : cue.plainText).filter { !$0.isWhitespace }.count
            return EditorRow(id: cue.id, start: cue.start, end: cue.end, style: cue.style, actor: cue.actor,
                             original: cue.plainText, translation: isTranslated ? translatedText : "",
                             isComment: cue.isComment, skipReason: source.skipReason(at: cue.id), isTranslated: isTranslated,
                             readingSpeed: cue.isComment ? 0 : Double(visible) / seconds)
        }
    }
}
