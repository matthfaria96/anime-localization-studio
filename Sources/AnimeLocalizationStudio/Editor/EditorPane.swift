import DubbingKit
import SubtitleKit
import SwiftUI

/// Bottom half of the episode: search bar, the line table and the selected line's editor.
struct EditorPane: View {
    @Bindable var workspace: WorkspaceModel
    @State private var showStyles = false
    @State private var showShift = false
    @State private var showCharacter = false
    @Environment(\.undoManager) private var undoManager

    var editor: EditorModel { workspace.editor }

    var body: some View {
        if editor.hasDocument {
            VStack(spacing: 0) {
                EditorToolbar(editor: editor, showStyles: $showStyles, showShift: $showShift, showCharacter: $showCharacter,
                              canIdentify: !workspace.isBusy && !workspace.audioTracks.isEmpty) {
                    workspace.identifySpeakers(undoManager: undoManager)
                }
                Divider()
                // A plain stack honors the width it is given; split views size by content and overflow.
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        LinesTable(workspace: workspace)
                            .frame(maxWidth: .infinity)
                        Divider()
                        LineDetailView(workspace: workspace)
                            .frame(width: proxy.size.width >= 900 ? 360 : 300)
                    }
                }
            }
            .modifier(SpeakerModelConsent(workspace: workspace))
            .sheet(isPresented: $showStyles) { StylesAndFontsSheet(workspace: workspace) }
            // Test hook for captures: ALS_STYLES=1 opens Estilos e fontes.
            .onAppear { if ProcessInfo.processInfo.environment["ALS_STYLES"] == "1" { showStyles = true } }
            .sheet(isPresented: $showCharacter) { CharacterSheet(editor: editor) }
            .sheet(isPresented: $showShift) { ShiftTimingSheet(editor: editor) }
            // Observing the playback time here would rebuild the whole table 30 times a second.
            .background { PlaybackFollower(workspace: workspace) }
        } else {
            EmptyStateView(title: "Este vídeo não tem legenda de texto",
                           message: "Comece uma em branco, importe um arquivo ou deixe o app criar a legenda ouvindo o áudio, no tempo de cada fala.",
                           systemImage: "captions.bubble") {
                Button("Começar em branco") { workspace.requestNewSubtitle(.blank(language: workspace.app.settings.targetLanguage)) }
                    .hint("Começar em branco", "Uma legenda vazia, no idioma de saída escolhido em Ajustes, para escrever do zero.")
                Button("Importar arquivo…") { workspace.requestNewSubtitle(.importFile) }
                    .hint("Importar arquivo", "Abre um arquivo ASS, SSA ou SRT do disco.")
                Button("Criar a partir do áudio…") { workspace.showFromAudio = true }
                    .buttonStyle(.glassProminent)
                    .disabled(workspace.isBusy || workspace.audioTracks.isEmpty)
                    .hint("Criar a partir do áudio", "Ouve o vídeo e escreve o que é dito, no idioma falado, no tempo certo. Tudo no Mac.")
                if !workspace.bitmapSubtitleTracks.isEmpty {
                    Menu("Reconhecer texto (OCR)") {
                        ForEach(TranscriptionLanguage.all, id: \.code) { language in
                            Button(language.name) { workspace.recognizeBitmapSubtitle(language: language.code) }
                        }
                    }
                    .fixedSize()
                    .disabled(workspace.isBusy)
                    .hint("Reconhecer texto (OCR)", "Lê as legendas em imagem de Blu-ray (PGS) e as transforma em texto editável, no próprio Mac. Escolha o idioma da legenda.")
                }
            }
            .modifier(SpeakerModelConsent(workspace: workspace))
        }
    }
}

private struct EditorToolbar: View {
    @Bindable var editor: EditorModel
    @Binding var showStyles: Bool
    @Binding var showShift: Bool
    @Binding var showCharacter: Bool
    let canIdentify: Bool
    let identify: () -> Void
    @Environment(\.undoManager) private var undoManager
    @State private var lastReplaceCount: Int?
    @FocusState private var searchFocused: Bool

    @State private var showReplace = false

    var body: some View {
        // Full bar when it fits; otherwise a compact one, so the editor never overflows its column.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                filterPicker
                searchBox(replace: true)
                replaceControls
                Spacer(minLength: Theme.Spacing.s)
                tools
            }
            HStack(spacing: Theme.Spacing.s) {
                filterMenu
                searchBox(replace: false)
                Button("Substituir…", systemImage: "arrow.left.arrow.right") { showReplace = true }
                    .labelStyle(.iconOnly)
                    .hint("Substituir…", "Abre a busca e substituição: troque um texto em todas as falas de uma vez.")
                    .popover(isPresented: $showReplace, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text("Substituir “\(editor.searchQuery)”").font(.headline)
                            TextField("Substituir por", text: $editor.replacement).textFieldStyle(.roundedBorder).frame(width: 240)
                            HStack { replaceControls }
                        }
                        .padding(Theme.Spacing.l)
                        .controlSize(.small)
                    }
                Spacer(minLength: Theme.Spacing.xs)
                tools
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

    private var filterPicker: some View {
        Picker("Filtro", selection: $editor.filter) {
            ForEach(editor.availableFilters) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .hint("Filtro", "Mostra todas as falas, só as que ainda não foram traduzidas, as que não são traduzíveis (karaokê, desenhos, comentários), as rápidas demais para ler ou as com possíveis erros de ortografia.")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filtro", selection: $editor.filter) {
                ForEach(editor.availableFilters) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: editor.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .hint("Filtro: \(editor.filter.label)", "Mostra todas as falas, só as sem tradução, as não traduzíveis, as rápidas demais ou as com possíveis erros de ortografia.")
    }

    private func searchBox(replace: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar nas falas", text: $editor.searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .frame(minWidth: replace ? 120 : 80)
                .hint("Buscar (⌘F)", "Filtra a lista pelas falas que contêm este texto, no original, na tradução ou no nome do personagem.")
            if replace {
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).imageScale(.small)
                TextField("Substituir por", text: $editor.replacement)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 100)
                    .hint("Substituir por", "Texto que entra no lugar do que foi buscado quando você clica em “Substituir tudo”.")
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 5)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.small))
    }

    @ViewBuilder
    private var replaceControls: some View {
        if !editor.editsOriginal {
            Picker("Onde", selection: $editor.searchSide) {
                ForEach(DocumentSide.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .hint("Onde substituir", "Escolhe se “Substituir tudo” altera a tradução ou a legenda original.")
        }
        Toggle("Aa", isOn: $editor.caseSensitive)
            .toggleStyle(.button)
            .hint("Maiúsculas e minúsculas", "Ligado: a busca diferencia “Kirito” de “kirito”. Desligado: encontra os dois.")
        Button("Substituir tudo") { lastReplaceCount = editor.replaceAll(undoManager: undoManager) }
            .disabled(editor.searchQuery.isEmpty)
            .hint("Substituir tudo", "Troca o texto buscado em todas as falas de uma vez. Só mexe no texto visível; tags de formatação {\\…} nunca são alteradas. ⌘Z desfaz.")
        if let count = lastReplaceCount {
            Text("\(count) falas alteradas").font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }

    @ViewBuilder
    private var tools: some View {
        Toggle(isOn: $editor.followPlayback) { Image(systemName: "dot.radiowaves.forward") }
            .toggleStyle(.button)
            .hint("Acompanhar o vídeo", "Ligado: durante a reprodução, a lista seleciona sozinha a fala que está aparecendo na tela.")
        Button("Inserir fala", systemImage: "plus") {
            if let id = editor.selection.max() ?? editor.rows.last?.id { editor.insertLine(after: id, undoManager: undoManager) }
        }
        .labelStyle(.iconOnly)
        .hint("Inserir fala", "Cria uma fala vazia logo depois da selecionada, no intervalo até a próxima. Para excluir falas, selecione e aperte ⌫.")
        .disabled(editor.rows.isEmpty)
        Button("Deslocar tempos…", systemImage: "clock.arrow.2.circlepath") { showShift = true }
            .labelStyle(.iconOnly)
            .hint("Deslocar tempos", "Adianta ou atrasa todas as falas (ou só as selecionadas) por alguns milissegundos, para sincronizar a legenda com o vídeo.")
        Menu {
            Button("Definir personagem das falas selecionadas…") { showCharacter = true }
                .disabled(editor.selection.isEmpty)
            Button("Identificar quem fala pelo áudio") { identify() }
                .disabled(!canIdentify)
        } label: {
            Label("Personagens", systemImage: "person.2")
        }
        .menuStyle(.button)
        .fixedSize()
        .hint("Personagens", "Diga quem fala em cada linha (é o que a dublagem usa para escolher a voz). No ASS o nome vai no campo Name, que não aparece na tela; no SRT fica guardado no app, fora do arquivo.")
        Button("Estilos e fontes…", systemImage: "paintpalette") { showStyles = true }
            .hint("Estilos e fontes", "Criar, duplicar, renomear, apagar e editar estilos; ver de onde vem cada fonte, adicionar fontes ao vídeo e extrair as que ele tem.")
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
                .width(min: 28, ideal: 34, max: 50)
                TableColumn("Tempo") { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(SubtitleTime.formatDisplay(row.start)).monospacedDigit()
                        Text(SubtitleTime.formatDisplay(row.end)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("De \(SubtitleTime.formatDisplay(row.start)) a \(SubtitleTime.formatDisplay(row.end))")
                }
                .width(min: 56, ideal: 66, max: 90)
                TableColumn("Personagem") { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.actor.isEmpty ? row.style : row.actor).lineLimit(1)
                        if !row.actor.isEmpty && !row.style.isEmpty { Text(row.style).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                .width(min: 60, ideal: 90, max: 180)
                if editor.editsOriginal && editor.referenceTitle != nil {
                    TableColumn(LocalizedStringKey(editor.referenceTitle.map { "Ao lado · \($0)" } ?? "Ao lado")) { row in
                        Text(editor.reference[row.id]?.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "—")
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 220)
                }
                TableColumn(editor.editsOriginal ? "Texto" : "Original") { row in
                    Text(row.original.replacingOccurrences(of: "\n", with: " ⏎ "))
                        .lineLimit(2)
                        .foregroundStyle(row.isComment ? .tertiary : .primary)
                        .italic(row.isComment)
                }
                .width(min: 80, ideal: 220)
                if !editor.editsOriginal {
                    TableColumn("Tradução") { row in TranslationCell(row: row, maxReadingSpeed: editor.maxReadingSpeed) }
                        .width(min: 80, ideal: 220)
                }
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
                // After the table's own update pass, never inside it (NSTableView reentrancy).
                if let id = selection.first { Task { @MainActor in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } } }
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
                        .hintVerbatim("Leitura rápida demais", "\(Int(row.readingSpeed)) caracteres por segundo. Fica difícil ler a tempo; encurte a frase ou aumente a duração da fala.")
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

/// Asks before downloading the speaker-identification models, with size, license and credits.
struct SpeakerModelConsent: ViewModifier {
    @Bindable var workspace: WorkspaceModel

    func body(content: Content) -> some View {
        content.confirmationDialog("Baixar os modelos de identificação de falantes?",
                                   isPresented: Binding(get: { workspace.pendingDiarizationDownload != nil },
                                                        set: { if !$0 { workspace.pendingDiarizationDownload = nil } })) {
            Button("Baixar (\(SpeakerDiarization.downloadSize)) e continuar") {
                let retry = workspace.pendingDiarizationDownload
                workspace.pendingDiarizationDownload = nil
                retry?()
            }
        } message: {
            Text("Para saber quem fala, o app usa modelos que rodam no próprio Mac (Neural Engine): \(SpeakerDiarization.modelCredits). Licença CC-BY-4.0. O download vem do Hugging Face uma única vez e fica guardado no app; o áudio nunca sai do Mac.")
        }
    }
}

/// Selects the line being played. Lives in its own view so only it re-renders with the clock,
/// and the selection change is deferred out of the table's update pass.
private struct PlaybackFollower: View {
    let workspace: WorkspaceModel

    var body: some View {
        Color.clear
            .onChange(of: workspace.player.currentTime) { _, time in
                let editor = workspace.editor
                guard editor.followPlayback, workspace.player.isPlaying, let line = editor.line(at: time), !editor.selection.contains(line) else { return }
                Task { @MainActor in editor.selection = [line] }
            }
    }
}
