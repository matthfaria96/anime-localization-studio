import SubtitleKit
import SwiftUI

/// Editor for the selected line: its text first (what is edited most), then timing, style,
/// character and position on screen. Text is edited raw (tags visible) so nothing is lost;
/// the plain preview sits under it.
struct LineDetailView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.undoManager) private var undoManager
    @State private var startDraft = ""
    @State private var endDraft = ""
    /// What is selected in the text, for the formatting buttons.
    @State private var textSelection: TextSelection?
    @AppStorage("linePanelDocked") private var docked = false

    var editor: EditorModel { workspace.editor }
    var index: Int? { editor.selection.count == 1 ? editor.selection.first : nil }

    var body: some View {
        Group {
            if let index, let cue = editor.cue(index, side: .original) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        header(cue)
                        if let title = editor.referenceTitle {
                            let beside = editor.editsOriginal ? editor.reference[index] : cue.plainText
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text("Ao lado · \(title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(beside ?? "Sem fala correspondente neste tempo.")
                                    .foregroundStyle(beside == nil ? .tertiary : .secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(Theme.Spacing.s)
                                    .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.small))
                            }
                            .hint("Ao lado", "A fala da outra legenda no mesmo tempo, só para consulta: só a legenda em Editando é editada. Selecione e copie se quiser.")
                        }
                        if editor.editsOriginal {
                            textEditor("Texto", text: Bindable(editor).originalDraft, side: .original, index: index, prominent: true)
                        } else {
                            textEditor("Texto", text: Bindable(editor).translationDraft, side: .translation, index: index, prominent: true)
                        }
                        warnings(cue)
                        timing(cue, index: index)
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
                .overlay(alignment: .topTrailing) { dockButton.padding(Theme.Spacing.l) }
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
                .hint("Reproduzir esta fala", "Toca o vídeo do início ao fim desta fala e pausa, para conferir o tempo e o texto.")
            dockButton
        }
    }

    /// Pins the panel to the whole right side of Legendar, or puts it back beside the list.
    private var dockButton: some View {
        Button(docked ? "Voltar para junto da lista" : "Fixar na lateral", systemImage: docked ? "rectangle.bottomhalf.inset.filled" : "sidebar.trailing") {
            docked.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .hint(docked ? "Voltar para junto da lista" : "Fixar na lateral",
              docked ? "O painel da fala volta para baixo, ao lado da lista de falas."
                     : "O painel da fala cresce e ocupa toda a lateral direita, ao lado do vídeo e da lista. Clique de novo para voltar.")
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
            // One row when there is room, two rows in narrow panes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.xs) { nudges(index: index, cue: cue); Divider().frame(height: 14); videoButtons(index: index, cue: cue) }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.xs) { nudges(index: index, cue: cue) }
                    HStack(spacing: Theme.Spacing.xs) { videoButtons(index: index, cue: cue) }
                }
            }
            .controlSize(.small)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.s, verticalSpacing: Theme.Spacing.s) {
                if !editor.styleNames.isEmpty {
                    GridRow {
                        Text("Estilo").foregroundStyle(.secondary)
                        Picker("Estilo", selection: Binding(get: { cue.style }, set: { editor.setStyle($0, index: index, undoManager: undoManager) })) {
                            ForEach(editor.styleNames, id: \.self) { Text($0).tag($0) }
                            if !editor.styleNames.contains(cue.style) { Text(cue.style).tag(cue.style) }
                        }
                        .labelsHidden()
                        .hint("Estilo", "Estilo ASS desta fala (fonte, cor, posição). Os estilos são editados em “Estilos e fontes…”.")
                    }
                }
                GridRow {
                    Text("Personagem").foregroundStyle(.secondary)
                    CharacterField(editor: editor, index: index, actor: cue.actor)
                }
            }
            position(index: index)
        }
    }

    /// Where the line shows on screen and the ways to change it: the grid (an area of the
    /// screen), arrows and X/Y (an exact point, `\pos`), dragging on the video, and back to the style.
    private func position(index: Int) -> some View {
        let row = editor.rows.first { $0.id == index }
        let alignment = row?.alignment ?? 2
        let placeable = editor.canPlace(index)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Posição na tela")
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                PositionPad(alignment: row?.isInArea == false ? nil : alignment, point: row?.screenPoint) {
                    editor.setAlignment($0, lines: [index], undoManager: undoManager)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row?.isInArea == false
                         ? "Ponto livre · \(row?.screenPoint.map { ScreenPosition.name(ScreenPosition.area(of: $0)).lowercased() } ?? "")"
                         : ScreenPosition.name(alignment))
                        .font(.callout)
                    Text(positionSource(row, placeable: placeable)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if row?.alignmentFromLine == true || row?.hasExactPosition == true {
                        Button("Usar a do estilo") { editor.setAlignment(nil, lines: [index], undoManager: undoManager) }
                            .buttonStyle(.link).font(.caption)
                            .hint("Usar a posição do estilo", "Tira a posição própria desta fala (\\an e \\pos); ela volta a seguir o estilo.")
                    }
                }
            }
            if placeable, let anchor = editor.anchor(of: index), let frame = editor.playResolution {
                HStack(spacing: Theme.Spacing.s) {
                    arrows(index: index, frame: frame)
                    Spacer(minLength: 0)
                    coordinate("X", anchor.x) { editor.setPosition(ASSPoint(x: $0, y: anchor.y), line: index, undoManager: undoManager) }
                    coordinate("Y", anchor.y) { editor.setPosition(ASSPoint(x: anchor.x, y: $0), line: index, undoManager: undoManager) }
                }
                .controlSize(.small)
                Text("Ou arraste a fala no vídeo (com ela na tela e o vídeo pausado).").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .hint("Posição na tela", "A grade põe a fala numa área da tela (em cima, no meio, embaixo…). As setas, X e Y e arrastar no vídeo põem num ponto exato. ⌘Z desfaz.")
    }

    private func positionSource(_ row: EditorRow?, placeable: Bool) -> String {
        guard editor.playResolution != nil else { return "Em SRT há só as posições da grade (\\an); arrastar e ponto exato são do ASS." }
        if !placeable { return "Esta fala se move sozinha (\\move): a grade muda o lado de onde ela se ancora, e arrastar não se aplica." }
        if row?.hasExactPosition == true { return "Num ponto exato definido nesta fala (\\pos), fora das áreas da grade. Clique numa área para pô-la lá." }
        if row?.isInArea == false { return "As margens do estilo “\(row?.style ?? "")” põem a fala fora da área \(ScreenPosition.name(row?.alignment ?? 2).lowercased())." }
        if row?.alignmentFromLine == true { return "Definida nesta fala." }
        return "Vem do estilo “\(row?.style.isEmpty == false ? row!.style : "padrão")”."
    }

    /// ↑ ↓ ← →: 1% of the frame per click, 1 script pixel with ⌥.
    private func arrows(index: Int, frame: CGSize) -> some View {
        HStack(spacing: 2) {
            ForEach([("arrow.left", -1.0, 0.0, "esquerda"), ("arrow.up", 0, -1, "cima"), ("arrow.down", 0, 1, "baixo"), ("arrow.right", 1, 0, "direita")],
                    id: \.0) { icon, dx, dy, name in
                Button("Mover para \(name)", systemImage: icon) {
                    let step = NSEvent.modifierFlags.contains(.option) ? 1 : max(1, (frame.height / 100).rounded())
                    editor.nudge(index, dx: dx * step, dy: dy * step, undoManager: undoManager)
                }
                .labelStyle(.iconOnly)
                .hintVerbatim("Mover para \(name)", "Move a fala um pouco para \(name) (1% da tela; com ⌥, 1 ponto). Ela passa a ter um ponto exato (\\pos).")
            }
        }
    }

    private func coordinate(_ name: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(.secondary)
            TextField(name, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 54)
                .hintVerbatim("Posição \(name)", "\(name == "X" ? "Distância da esquerda" : "Distância do topo") em pontos do script (\(name == "X" ? "PlayResX" : "PlayResY")). Digite e aperte Return.")
        }
    }

    @ViewBuilder
    private func nudges(index: Int, cue: SubtitleCue) -> some View {
        nudge("−100 ms", start: -100, end: -100, index: index, cue: cue)
        nudge("+100 ms", start: 100, end: 100, index: index, cue: cue)
    }

    @ViewBuilder
    private func videoButtons(index: Int, cue: SubtitleCue) -> some View {
        Button("Início no vídeo") {
            editor.setTiming(start: workspace.player.currentTime, end: max(cue.end, workspace.player.currentTime + 500), index: index, undoManager: undoManager)
        }
        .hint("Início no vídeo", "Faz a fala começar exatamente onde o vídeo está parado agora.")
        Button("Fim no vídeo") {
            editor.setTiming(start: cue.start, end: max(cue.start, workspace.player.currentTime), index: index, undoManager: undoManager)
        }
        .hint("Fim no vídeo", "Faz a fala terminar exatamente onde o vídeo está parado agora.")
    }

    private func timeField(_ title: LocalizedStringKey, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .font(Theme.monoDigits)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 96, maxWidth: 116)
                .onSubmit(commit)
                .labelsHidden()
                .hint("Tempo", "Digite o tempo (ex.: 0:01:23.45) e aperte Return para aplicar.")
        }
    }

    private func nudge(_ title: String, start: Int, end: Int, index: Int, cue: SubtitleCue) -> some View {
        Button(title) { editor.setTiming(start: cue.start + start, end: cue.end + end, index: index, undoManager: undoManager) }
            .hintVerbatim(title, start < 0 ? "Adianta a fala inteira (início e fim) em 0,1 segundo." : "Atrasa a fala inteira (início e fim) em 0,1 segundo.")
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
                        .hint("Aplicar (⌘↩)", "Grava o texto que você digitou nesta fala. Trocar de fala também aplica.")
                }
            }
            FormatBar(html: editor.usesHTMLMarkup, style: editor.cue(index, side: .original).flatMap { editor.styleInfo($0.style) },
                      lineDuration: editor.cue(index, side: .original)?.duration) { change in
                let raw = text.wrappedValue
                var range: Range<String.Index>?
                if case .selection(let selected) = textSelection?.indices, !selected.isEmpty, selected.upperBound <= raw.endIndex { range = selected }
                text.wrappedValue = change(raw, range)
                textSelection = nil
                editor.commitDrafts()
            }
            TextEditor(text: text, selection: $textSelection)
                .font(.system(prominent ? .body : .callout, design: .default))
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.s)
                .frame(minHeight: prominent ? 76 : 56)
                .background(.background, in: .rect(cornerRadius: Theme.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator))
                .accessibilityLabel(title)
            let html = editor.usesHTMLMarkup
            // Shown when the line has formatting or other tags, so it reads as it will look.
            if ASSText.plainText(text.wrappedValue, htmlMarkup: html) != text.wrappedValue {
                Text(FormatBar.preview(text.wrappedValue, html: html))
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, Theme.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.82), in: .rect(cornerRadius: Theme.Radius.small))
                    .hint("Como fica", "A fala como aparece no vídeo: itálico, negrito, sublinhado, riscado e cores, sem os códigos.")
            }
            if let cue = editor.cue(index, side: .original), !editor.usesHTMLMarkup {
                KaraokeSection(text: text, workspace: workspace, start: cue.start, end: cue.end) { editor.commitDrafts() }
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

/// Who says the line: type a name, or pick one already written in this subtitle, so the same
/// character is never spelled two ways. The name is saved on Return or when leaving the field.
struct CharacterField: View {
    let editor: EditorModel
    let index: Int
    let actor: String
    @Environment(\.undoManager) private var undoManager
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("Nome do personagem", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
            Menu {
                if editor.actorNames.isEmpty {
                    Text("Nenhum personagem escrito ainda")
                } else {
                    ForEach(editor.actorNames, id: \.self) { name in
                        Button(name) { draft = name; commit() }
                    }
                }
                if !actor.isEmpty {
                    Divider()
                    Button("Sem personagem") { draft = ""; commit() }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .hint("Escolher personagem", "Os nomes que você já escreveu nesta legenda, para não digitar diferente.")
        }
        .frame(minWidth: 140)
        .onAppear { draft = actor }
        .onChange(of: actor) { draft = actor }
        .onChange(of: index) { draft = actor }
        .hint("Personagem", "Quem diz esta fala. Escreva o nome ou escolha um já usado na seta. Usado no contexto da tradução e para dar a voz certa na dublagem.")
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        if name != actor { editor.setActor(name, index: index, undoManager: undoManager) }
    }
}
