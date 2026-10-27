import SubtitleKit
import SwiftUI

/// Styles (create, duplicate, rename, delete, edit) and fonts (what the subtitle uses, where
/// each comes from, adding and extracting). Style changes go to the original and the
/// translation alike, so both keep the same structure; ⌘Z undoes them.
struct StylesAndFontsSheet: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Seção", selection: $tab) {
                Text("Estilos").tag(0)
                Text("Fontes").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(Theme.Spacing.m)
            Divider()
            if tab == 0 { StylesPane(workspace: workspace) } else { FontsPane(workspace: workspace) }
            Divider()
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.m)
        }
        .frame(width: 820, height: 600)
    }
}

// MARK: Styles

private struct StylesPane: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.undoManager) private var undoManager
    @State private var selected = 0
    @State private var draft: ASSStyleInfo = .fallback
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var replacement = ""

    private var editor: EditorModel { workspace.editor }
    private var styles: [ASSStyleInfo] {
        guard case .ass(let doc) = editor.source else { return [] }
        return doc.styles.map { ASSStyleInfo(record: $0, isSSA: doc.isSSA) }
    }
    private var current: ASSStyleInfo? { styles.indices.contains(selected) ? styles[selected] : nil }

    var body: some View {
        if styles.isEmpty {
            EmptyStateView(title: "Esta legenda não tem estilos",
                           message: "Legendas SRT guardam só o texto. Para usar estilos (fonte, cor, posição), use uma legenda ASS.",
                           systemImage: "paintpalette") { EmptyView() }
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: Binding(get: { selected }, set: { select($0 ?? 0) })) {
                        ForEach(Array(styles.enumerated()), id: \.offset) { offset, style in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.name)
                                Text("\(style.fontName) · \(Int(style.fontSize)) · \(Plural.count(editor.linesUsingStyle(style.name), "fala", "falas"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(offset)
                        }
                    }
                    Divider()
                    HStack(spacing: Theme.Spacing.xs) {
                        Button("Novo estilo", systemImage: "plus") { add(named: "Novo estilo") }
                            .hint("Novo estilo", "Cria um estilo a partir do selecionado. Depois mude o nome, a fonte e as cores.")
                        Button("Duplicar", systemImage: "plus.square.on.square") { add(named: current?.name ?? "Estilo") }
                            .hint("Duplicar estilo", "Cria uma cópia do estilo selecionado.")
                        Button("Apagar…", systemImage: "minus") {
                            replacement = styles.first { $0.name != current?.name }?.name ?? ""
                            confirmDelete = true
                        }
                        .disabled(styles.count < 2)
                        .hint("Apagar estilo", "Pergunta para qual estilo vão as falas que usam este.")
                        Spacer()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(Theme.Spacing.s)
                }
                .frame(width: 230)
                Divider()
                detail
            }
            .onAppear { select(min(selected, styles.count - 1)) }
            .sheet(isPresented: $confirmDelete) { deleteSheet }
        }
    }

    private var detail: some View {
        Form {
            Section("Estilo") {
                TextField("Nome", text: $name)
                    .onSubmit { rename() }
                    .hint("Nome do estilo", "Aperte Return para renomear. Todas as falas com este estilo passam a usar o nome novo.")
            }
            Section("Fonte") {
                HStack {
                    TextField("Fonte", text: $draft.fontName)
                    Menu("Escolher") {
                        ForEach(workspace.availableFontFamilies, id: \.self) { family in Button(family) { draft.fontName = family } }
                    }
                    .fixedSize()
                    .hint("Escolher fonte", "As fontes do Mac, as anexadas ao vídeo e as que você adicionou.")
                }
                fontState
                Stepper(value: $draft.fontSize, in: 4...400, step: 1) { Text("Tamanho: \(Int(draft.fontSize))") }
                Toggle("Negrito", isOn: $draft.bold)
                Toggle("Itálico", isOn: $draft.italic)
            }
            Section("Cores") {
                ColorPicker("Texto", selection: colorBinding(\.primary))
                ColorPicker("Contorno", selection: colorBinding(\.outlineColor))
            }
            Section("Borda e posição") {
                Stepper(value: $draft.outline, in: 0...20, step: 0.5) { Text("Contorno: \(draft.outline, format: .number)") }
                Stepper(value: $draft.shadow, in: 0...20, step: 0.5) { Text("Sombra: \(draft.shadow, format: .number)") }
                Picker("Alinhamento", selection: $draft.alignment) {
                    ForEach([7, 8, 9, 4, 5, 6, 1, 2, 3], id: \.self) { value in Text(alignmentName(value)).tag(value) }
                }
                Stepper(value: $draft.marginV, in: 0...1_000, step: 1) { Text("Margem vertical: \(Int(draft.marginV))") }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Desfazer mudanças") { if let current { draft = current } }
                        .disabled(current == draft)
                    Button("Aplicar") { editor.updateStyle(draft, at: selected, undoManager: undoManager) }
                        .buttonStyle(.glassProminent)
                        .disabled(current == draft)
                        .hint("Aplicar", "Grava as mudanças no estilo; vale para todas as falas que o usam. ⌘Z desfaz.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var fontState: some View {
        let status = workspace.fontStatuses().first { $0.family.caseInsensitiveCompare(draft.fontName) == .orderedSame }
        switch status?.source {
        case .attached: Label("Anexada ao vídeo", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
        case .added: Label("Adicionada; vai para o vídeo ao gravar", systemImage: "plus.circle").font(.caption).foregroundStyle(.secondary)
        case .installed: Label("Instalada neste Mac, mas não anexada ao vídeo: outros players podem trocar a fonte. Adicione-a em Fontes.", systemImage: "desktopcomputer")
            .font(.caption).foregroundStyle(Theme.warning)
        case .missing: Label("Não encontrada: adicione o arquivo da fonte em Fontes.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
        case nil: EmptyView()
        }
    }

    private var deleteSheet: some View {
        let lines = editor.linesUsingStyle(current?.name ?? "")
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Apagar o estilo “\(current?.name ?? "")”?").font(.title3.weight(.semibold))
            if lines > 0 {
                Picker("\(Plural.count(lines, "fala usa", "falas usam")) este estilo. Passar para:", selection: $replacement) {
                    ForEach(styles.filter { $0.name != current?.name }, id: \.name) { Text($0.name).tag($0.name) }
                }
            } else {
                Text("Nenhuma fala usa este estilo.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancelar") { confirmDelete = false }.keyboardShortcut(.cancelAction)
                Button("Apagar estilo", role: .destructive) {
                    editor.removeStyle(at: selected, movingLinesTo: replacement, undoManager: undoManager)
                    confirmDelete = false
                    select(max(0, selected - 1))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(lines > 0 && replacement.isEmpty)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 440)
    }

    private func add(named base: String) {
        if let index = editor.addStyle(copying: selected, named: base, undoManager: undoManager) { select(index) }
    }

    private func rename() {
        guard let current, name != current.name else { return }
        editor.renameStyle(at: selected, to: name, undoManager: undoManager)
        select(selected)
    }

    private func select(_ index: Int) {
        selected = index
        if styles.indices.contains(index) {
            draft = styles[index]
            name = styles[index].name
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<ASSStyleInfo, ASSColor>) -> Binding<Color> {
        Binding {
            let c = draft[keyPath: keyPath]
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.opacity)
        } set: { color in
            let resolved = color.resolve(in: EnvironmentValues())
            draft[keyPath: keyPath] = ASSColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue), opacity: Double(resolved.opacity))
        }
    }

    private func alignmentName(_ value: Int) -> String {
        let vertical = ["Inferior", "Meio", "Superior"][(value - 1) / 3]
        let horizontal = ["esquerda", "centro", "direita"][(value - 1) % 3]
        return "\(vertical) · \(horizontal) (\(value))"
    }
}

// MARK: Fonts

private struct FontsPane: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        let statuses = workspace.fontStatuses()
        Form {
            Section {
                if statuses.isEmpty { Text("A legenda não pede nenhuma fonte específica.").foregroundStyle(.secondary) }
                ForEach(statuses) { status in
                    LabeledContent(status.family) { label(status.source) }
                }
            } header: {
                Text("Fontes que a legenda usa")
            } footer: {
                Text("Para a legenda aparecer igual em qualquer player, cada fonte precisa estar anexada ao vídeo. Fontes adicionadas aqui são anexadas em “Gravar no vídeo…”.")
            }
            Section("Adicionadas") {
                ForEach(workspace.addedFontFiles, id: \.self) { file in
                    LabeledContent(file.lastPathComponent) {
                        Button("Remover", systemImage: "minus.circle") { workspace.removeAddedFont(file) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .hint("Remover", "Tira a fonte da lista; ela não será anexada.")
                    }
                }
                HStack {
                    Button("Adicionar fontes…", systemImage: "plus") { workspace.addFonts() }
                        .hint("Adicionar fontes", "Escolha arquivos TTF, OTF ou TTC. Eles serão anexados ao vídeo junto com a legenda.")
                    Spacer()
                    Button("Extrair fontes do vídeo…", systemImage: "square.and.arrow.up") { workspace.extractFonts() }
                        .disabled(workspace.info?.attachments.contains(where: \.isFont) != true || workspace.isBusy)
                        .hint("Extrair fontes", "Salva numa pasta as fontes anexadas ao vídeo, sem alterá-lo.")
                }
            }
            if let notice = workspace.notice { InlineMessage(kind: notice.kind, text: notice.text) }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func label(_ source: FontStatus.Source) -> some View {
        switch source {
        case .attached: Label("Anexada ao vídeo", systemImage: "paperclip").foregroundStyle(Theme.translated)
        case .added: Label("Vai para o vídeo ao gravar", systemImage: "plus.circle").foregroundStyle(.secondary)
        case .installed: Label("Só neste Mac", systemImage: "desktopcomputer").foregroundStyle(Theme.warning)
        case .missing: Label("Faltando", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
        }
    }
}
