import SubtitleKit
import SwiftUI

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
