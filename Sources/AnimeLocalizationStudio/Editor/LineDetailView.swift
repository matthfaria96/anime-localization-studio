import SubtitleKit
import SwiftUI

/// Editor for the selected line: timing, style, character, original and translation text.
/// Text is edited raw (tags visible) so nothing is lost; the plain preview sits under it.
struct LineDetailView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.undoManager) private var undoManager
    @State private var startDraft = ""
    @State private var endDraft = ""

    var editor: EditorModel { workspace.editor }
    var index: Int? { editor.selection.count == 1 ? editor.selection.first : nil }

    var body: some View {
        Group {
            if let index, let cue = editor.cue(index, side: .original) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        header(cue)
                        timing(cue, index: index)
                        textEditor("Tradução", text: Bindable(editor).translationDraft, side: .translation, index: index, prominent: true)
                        textEditor("Original", text: Bindable(editor).originalDraft, side: .original, index: index, prominent: false)
                        warnings(cue)
                    }
                    .padding(Theme.Spacing.l)
                }
                .onAppear {
                    editor.undoManager = undoManager
                    if editor.draftIndex != index { editor.beginEditing(index) }
                    loadTiming(cue)
                }
                .onChange(of: index) { _, new in
                    // beginEditing applies the drafts of the line that was selected before.
                    editor.beginEditing(new)
                    if let cue = editor.cue(new, side: .original) { loadTiming(cue) }
                }
                .onChange(of: editor.rows) { if let cue = editor.cue(index, side: .original) { loadTiming(cue) } }
            } else {
                VStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "text.cursor").font(.title).foregroundStyle(.tertiary)
                    Text(editor.selection.count > 1 ? "\(editor.selection.count) falas selecionadas" : "Selecione uma fala para editar")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .paneBackground()
        .onDisappear { editor.commitDrafts() }
        .onChange(of: editor.selection) { _, selection in if selection.count != 1 { editor.commitDrafts() } }
    }

    private func header(_ cue: SubtitleCue) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("Fala \(cue.id + 1)").font(.headline)
            if cue.isComment { Tag(text: "Comentário") }
            Spacer()
            Button("Reproduzir fala", systemImage: "play.circle") { workspace.player.play(from: cue.start, to: cue.end) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .help("Reproduzir só esta fala")
        }
    }

    private func timing(_ cue: SubtitleCue, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Tempo")
            HStack(spacing: Theme.Spacing.s) {
                timeField("Início", text: $startDraft) { commitTiming(index: index, cue: cue) }
                timeField("Fim", text: $endDraft) { commitTiming(index: index, cue: cue) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duração").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f s", Double(cue.duration) / 1_000)).monospacedDigit()
                }
            }
            HStack(spacing: Theme.Spacing.xs) {
                nudge("−100 ms", start: -100, end: -100, index: index, cue: cue)
                nudge("+100 ms", start: 100, end: 100, index: index, cue: cue)
                Divider().frame(height: 14)
                Button("Início no vídeo") {
                    editor.setTiming(start: workspace.player.currentTime, end: max(cue.end, workspace.player.currentTime + 500), index: index, undoManager: undoManager)
                }
                .help("Usar a posição atual do vídeo como início")
                Button("Fim no vídeo") {
                    editor.setTiming(start: cue.start, end: max(cue.start, workspace.player.currentTime), index: index, undoManager: undoManager)
                }
                .help("Usar a posição atual do vídeo como fim")
            }
            .controlSize(.small)
            if !editor.styleNames.isEmpty {
                HStack {
                    Picker("Estilo", selection: Binding(get: { cue.style }, set: { editor.setStyle($0, index: index, undoManager: undoManager) })) {
                        ForEach(editor.styleNames, id: \.self) { Text($0).tag($0) }
                        if !editor.styleNames.contains(cue.style) { Text(cue.style).tag(cue.style) }
                    }
                    TextField("Personagem", text: Binding(get: { cue.actor }, set: { editor.setActor($0, index: index, undoManager: undoManager) }))
                }
            }
        }
    }

    private func timeField(_ title: LocalizedStringKey, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .font(Theme.monoDigits)
                .textFieldStyle(.roundedBorder)
                .frame(width: 104)
                .onSubmit(commit)
                .labelsHidden()
        }
    }

    private func nudge(_ title: String, start: Int, end: Int, index: Int, cue: SubtitleCue) -> some View {
        Button(title) { editor.setTiming(start: cue.start + start, end: cue.end + end, index: index, undoManager: undoManager) }
    }

    private func textEditor(_ title: LocalizedStringKey, text: Binding<String>, side: DocumentSide, index: Int, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                SectionLabel(title)
                Spacer()
                if text.wrappedValue != editor.displayRaw(side, index) {
                    Button("Aplicar") { editor.commitDrafts() }
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Aplicar a alteração (⌘↩)")
                }
            }
            TextEditor(text: text)
                .font(.system(prominent ? .body : .callout, design: .default))
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.s)
                .frame(minHeight: prominent ? 76 : 56)
                .background(.background, in: .rect(cornerRadius: Theme.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator))
                .accessibilityLabel(title)
            let preview = ASSText.plainText(text.wrappedValue, htmlMarkup: editor.source?.usesHTMLMarkup ?? false)
            if preview != text.wrappedValue && !preview.isEmpty {
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func warnings(_ cue: SubtitleCue) -> some View {
        let features = cue.features
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if features.hasKaraoke { InlineMessage(kind: .info, text: "Linha de karaokê: por padrão não é traduzida, para não perder a sincronia das sílabas.") }
            if !workspace.usesFaithfulPreview {
                if features.hasDrawing { InlineMessage(kind: .info, text: "Desenho vetorial (\\p): preservado como está; ative a pré-visualização fiel (libass) em Ajustes para vê-lo.") }
                if features.hasAnimation { InlineMessage(kind: .info, text: "Usa animação (\\t, \\move ou \\fad): preservada no arquivo; ative a pré-visualização fiel (libass) em Ajustes para vê-la.") }
            }
        }
    }

    // MARK: Timing drafts

    private func loadTiming(_ cue: SubtitleCue) {
        startDraft = SubtitleTime.formatASS(cue.start)
        endDraft = SubtitleTime.formatASS(cue.end)
    }

    private func commitTiming(index: Int, cue: SubtitleCue) {
        let start = SubtitleTime.parseFlexible(startDraft) ?? cue.start
        let end = SubtitleTime.parseFlexible(endDraft) ?? cue.end
        editor.setTiming(start: start, end: max(start, end), index: index, undoManager: undoManager)
    }
}
