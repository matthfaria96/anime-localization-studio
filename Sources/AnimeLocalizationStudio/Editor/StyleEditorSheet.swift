import SubtitleKit
import SwiftUI

/// Edits the ASS styles. Changes go to both the original and the translation, so the two
/// documents keep the same structure.
struct StyleEditorSheet: View {
    let editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var selected = 0
    @State private var draft: ASSStyleInfo = .fallback

    private var styles: [ASSStyleInfo] {
        guard case .ass(let doc) = editor.source else { return [] }
        return doc.styles.map { ASSStyleInfo(record: $0, isSSA: doc.isSSA) }
    }

    var body: some View {
        NavigationSplitView {
            List(Array(styles.enumerated()), id: \.offset, selection: Binding(get: { selected }, set: { select($0 ?? 0) })) { offset, style in
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.name)
                    Text("\(style.fontName) · \(Int(style.fontSize))").font(.caption).foregroundStyle(.secondary)
                }
                .tag(offset)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form {
                Section("Fonte") {
                    TextField("Nome da fonte", text: $draft.fontName)
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
                    Text("A pré-visualização no vídeo é aproximada. Fontes que não estão instaladas no Mac aparecem com a fonte do sistema, mas continuam anexadas no MKV.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 640, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Aplicar") { editor.updateStyle(draft, at: selected, undoManager: undoManager) }
                    .disabled(styles.indices.contains(selected) ? styles[selected] == draft : true)
            }
        }
        .onAppear { select(0) }
    }

    private func select(_ index: Int) {
        selected = index
        if styles.indices.contains(index) { draft = styles[index] }
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

struct ShiftTimingSheet: View {
    let editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var milliseconds = 0
    @State private var onlySelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Deslocar tempos").font(.title3.weight(.semibold))
            Text("Adianta ou atrasa as falas, por exemplo quando a legenda veio de outra versão do vídeo.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Milissegundos", value: $milliseconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Stepper("", value: $milliseconds, step: 100).labelsHidden()
                Text("ms (negativo adianta)").foregroundStyle(.secondary)
            }
            Toggle("Somente as falas selecionadas (\(editor.selection.count))", isOn: $onlySelection)
                .disabled(editor.selection.isEmpty)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Deslocar") {
                    editor.shift(by: milliseconds, onlySelection: onlySelection, undoManager: undoManager)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(milliseconds == 0)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 440)
    }
}
