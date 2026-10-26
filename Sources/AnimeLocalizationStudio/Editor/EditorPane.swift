import SubtitleKit
import SwiftUI

/// Bottom half of the episode: search bar, the line table and the selected line's editor.
struct EditorPane: View {
    @Bindable var workspace: WorkspaceModel
    @State private var showStyles = false
    @State private var showShift = false
    @Environment(\.undoManager) private var undoManager

    var editor: EditorModel { workspace.editor }

    var body: some View {
        if editor.hasDocument {
            VStack(spacing: 0) {
                EditorToolbar(editor: editor, showStyles: $showStyles, showShift: $showShift)
                Divider()
                HSplitView {
                    LinesTable(workspace: workspace)
                        .frame(minWidth: 460)
                    LineDetailView(workspace: workspace)
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                }
            }
            .sheet(isPresented: $showStyles) { StyleEditorSheet(editor: editor) }
            .sheet(isPresented: $showShift) { ShiftTimingSheet(editor: editor) }
            .onChange(of: workspace.player.currentTime) { _, time in
                guard editor.followPlayback, workspace.player.isPlaying, let line = editor.line(at: time), !editor.selection.contains(line) else { return }
                editor.selection = [line]
            }
        } else {
            EmptyStateView(title: "Nenhuma legenda aberta",
                           message: "Escolha uma faixa de legenda de texto no inspetor, abra uma legenda externa (ASS, SSA ou SRT) ou transcreva o áudio do vídeo no próprio Mac.",
                           systemImage: "captions.bubble") {
                Button("Abrir legenda externa…") { workspace.openExternalSubtitle() }
                Menu("Transcrever o áudio") {
                    ForEach(TranscriptionLanguage.all, id: \.code) { language in
                        Button(language.name) { workspace.transcribeAudio(language: language.code) }
                    }
                }
                .fixedSize()
                .disabled(workspace.isBusy || workspace.audioTracks.isEmpty)
                .help("Reconhecimento de fala da Apple, no dispositivo")
                if !workspace.bitmapSubtitleTracks.isEmpty {
                    Menu("Reconhecer texto (OCR)") {
                        ForEach(TranscriptionLanguage.all, id: \.code) { language in
                            Button(language.name) { workspace.recognizeBitmapSubtitle(language: language.code) }
                        }
                    }
                    .fixedSize()
                    .disabled(workspace.isBusy)
                    .help("Lê as legendas em imagem (PGS) com o reconhecimento de texto da Apple, no dispositivo")
                }
            }
            .confirmationDialog("Baixar o modelo de fala?", isPresented: Binding(get: { workspace.pendingModelDownload != nil },
                                                                                  set: { if !$0 { workspace.pendingModelDownload = nil } })) {
                Button("Baixar e transcrever") {
                    if let language = workspace.pendingModelDownload { workspace.transcribeAudio(language: language, allowModelDownload: true) }
                    workspace.pendingModelDownload = nil
                }
            } message: {
                Text("O macOS precisa baixar o modelo de reconhecimento de fala para este idioma. O download é feito e gerenciado pelo sistema (modelo da Apple, uso no dispositivo) e fica disponível para outros apps.")
            }
        }
    }
}

private struct EditorToolbar: View {
    @Bindable var editor: EditorModel
    @Binding var showStyles: Bool
    @Binding var showShift: Bool
    @Environment(\.undoManager) private var undoManager
    @State private var lastReplaceCount: Int?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Picker("Filtro", selection: $editor.filter) {
                ForEach(LineFilter.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar nas falas", text: $editor.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(minWidth: 120)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).imageScale(.small)
                TextField("Substituir por", text: $editor.replacement)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 100)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 5)
            .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.small))

            Picker("Onde", selection: $editor.searchSide) {
                ForEach(DocumentSide.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Aa", isOn: $editor.caseSensitive)
                .toggleStyle(.button)
                .help("Diferenciar maiúsculas e minúsculas")
            Button("Substituir tudo") { lastReplaceCount = editor.replaceAll(undoManager: undoManager) }
                .disabled(editor.searchQuery.isEmpty)
                .help("Substitui só no texto visível; tags {\\…} nunca são alteradas")
            if let count = lastReplaceCount {
                Text("\(count) falas alteradas").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $editor.followPlayback) { Image(systemName: "dot.radiowaves.forward") }
                .toggleStyle(.button)
                .help("Acompanhar o vídeo: seleciona a fala que está tocando")
            Button("Inserir fala", systemImage: "plus") {
                if let id = editor.selection.max() ?? editor.rows.last?.id { editor.insertLine(after: id, undoManager: undoManager) }
            }
            .labelStyle(.iconOnly)
            .help("Inserir uma fala depois da selecionada (⌫ exclui as selecionadas)")
            .disabled(editor.rows.isEmpty)
            Button("Deslocar tempos…", systemImage: "clock.arrow.2.circlepath") { showShift = true }
                .labelStyle(.iconOnly)
                .help("Sincronizar: mover todas as falas ou as selecionadas")
            if !editor.styleNames.isEmpty {
                Button("Estilos…", systemImage: "paintpalette") { showStyles = true }
                    .labelStyle(.iconOnly)
                    .help("Editar estilos ASS")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .onChange(of: editor.searchQuery) { lastReplaceCount = nil }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }
}

struct LinesTable: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.undoManager) private var undoManager
    var editor: EditorModel { workspace.editor }

    var body: some View {
        ScrollViewReader { proxy in
            Table(editor.visibleRows, selection: Binding(get: { editor.selection }, set: { editor.selection = $0 })) {
                TableColumn("#") { row in
                    Text("\(row.id + 1)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 34, ideal: 40, max: 56)
                TableColumn("Início") { row in Text(SubtitleTime.formatDisplay(row.start)).monospacedDigit() }
                    .width(min: 62, ideal: 70, max: 90)
                TableColumn("Fim") { row in Text(SubtitleTime.formatDisplay(row.end)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 62, ideal: 70, max: 90)
                TableColumn("Estilo / Personagem") { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.actor.isEmpty ? row.style : row.actor).lineLimit(1)
                        if !row.actor.isEmpty && !row.style.isEmpty { Text(row.style).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                .width(min: 80, ideal: 110, max: 180)
                TableColumn("Original") { row in
                    Text(row.original.replacingOccurrences(of: "\n", with: " ⏎ "))
                        .lineLimit(2)
                        .foregroundStyle(row.isComment ? .tertiary : .primary)
                        .italic(row.isComment)
                }
                TableColumn("Tradução") { row in TranslationCell(row: row, maxReadingSpeed: editor.maxReadingSpeed) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Ir para a fala no vídeo") { if let id = ids.first { workspace.select(id, seek: true) } }
                Button("Inserir fala depois") { if let id = ids.max() { editor.insertLine(after: id, undoManager: undoManager) } }
                Button(ids.count > 1 ? "Excluir \(ids.count) falas" : "Excluir fala", role: .destructive) { editor.removeLines(ids, undoManager: undoManager) }
                Divider()
                Button("Reproduzir só esta fala") {
                    if let id = ids.first, let row = editor.rows.first(where: { $0.id == id }) { workspace.player.play(from: row.start, to: row.end) }
                }
            } primaryAction: { ids in
                if let id = ids.first { workspace.select(id, seek: true) }
            }
            .onDeleteCommand { editor.removeLines(editor.selection, undoManager: undoManager) }
            .onChange(of: editor.selection) { _, selection in
                if let id = selection.first { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct TranslationCell: View {
    let row: EditorRow
    let maxReadingSpeed: Double

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let reason = row.skipReason {
                Label(reason.label, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if row.isTranslated {
                Text(row.translation.replacingOccurrences(of: "\n", with: " ⏎ ")).lineLimit(2)
                if row.readingSpeed > maxReadingSpeed {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(Theme.warning)
                        .help("Leitura rápida: \(Int(row.readingSpeed)) caracteres por segundo")
                }
            } else {
                Text("Sem tradução").foregroundStyle(.tertiary).italic()
            }
        }
    }
}

enum TranscriptionLanguage {
    static let all: [(code: String, name: String)] = [("ja-JP", "Japonês"), ("en-US", "Inglês"), ("ko-KR", "Coreano"), ("zh-CN", "Chinês"),
                                                      ("es-ES", "Espanhol"), ("fr-FR", "Francês"), ("de-DE", "Alemão"), ("pt-BR", "Português (Brasil)")]
}
