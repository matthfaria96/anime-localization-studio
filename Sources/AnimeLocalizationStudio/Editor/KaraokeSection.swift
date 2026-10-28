import SubtitleKit
import SwiftUI

/// The karaoke of the selected line: how the syllables light up, each syllable's time, and
/// ways to set them (spread over the line, or marked while it plays).
struct KaraokeSection: View {
    @Binding var text: String
    let workspace: WorkspaceModel
    let start: Int
    let end: Int
    let commit: () -> Void
    @State private var marking = false

    var body: some View {
        if let line = KaraokeLine.parse(text.replacingOccurrences(of: "\n", with: "\\N")) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    SectionLabel("Karaokê")
                    Spacer()
                    let off = abs(line.totalMilliseconds - (end - start)) > 50
                    Text("Sílabas \(seconds(line.totalMilliseconds)) · fala \(seconds(end - start))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(off ? Theme.warning : .secondary)
                        .hint("Tempo das sílabas", off ? "As sílabas não somam o tempo da fala. “Distribuir pela fala” ou “Marcar no tempo” acertam isso." : "As sílabas somam o tempo da fala.")
                }
                Picker("Preenchimento", selection: Binding(get: { line.kind }, set: { kind in update { $0.kind = kind } })) {
                    Text("Troca de cor").tag(KaraokeKind.color)
                    Text("Preenche").tag(KaraokeKind.fill)
                    Text("Contorno").tag(KaraokeKind.outline)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .hint("Como a sílaba acende", "Troca de cor: muda de uma vez (\\k). Preenche: a cor corre da esquerda para a direita durante a sílaba (\\kf). Contorno: o contorno aparece (\\ko).")
                WrapLayout(spacing: 4) {
                    ForEach(Array(line.syllables.enumerated()), id: \.offset) { index, syllable in
                        chip(syllable, index: index)
                    }
                }
                HStack(spacing: Theme.Spacing.s) {
                    Button("Distribuir pela fala") { update { $0.distribute(over: end - start) } }
                        .hint("Distribuir pela fala", "Reparte o tempo da fala entre as sílabas, pelo número de letras de cada uma.")
                    Button("Marcar no tempo…") { marking = true }
                        .hint("Marcar no tempo", "A fala toca e você aperte Return quando cada sílaba começa a ser cantada.")
                    Spacer()
                    Button("Remover", role: .destructive) {
                        text = text.replacingOccurrences(of: #"\\(kf|ko|k|K)[0-9]+"#, with: "", options: .regularExpression).replacingOccurrences(of: "{}", with: "")
                        commit()
                    }
                    .hint("Remover karaokê", "Tira o tempo das sílabas; o texto fica como uma fala normal.")
                }
                .controlSize(.small)
            }
            .sheet(isPresented: $marking) {
                KaraokeMarkingSheet(line: line, start: start, end: end, player: workspace.player) { marked in
                    text = marked.text.replacingOccurrences(of: "\\N", with: "\n")
                    commit()
                }
            }
        }
    }

    private func chip(_ syllable: KaraokeLine.Syllable, index: Int) -> some View {
        VStack(spacing: 2) {
            Text(syllable.text.trimmingCharacters(in: .whitespaces).isEmpty ? "␣" : syllable.text.trimmingCharacters(in: .whitespaces))
                .font(.callout.weight(.medium))
            HStack(spacing: 2) {
                Button { update { $0.syllables[index].centiseconds = max(0, $0.syllables[index].centiseconds - 5) } } label: {
                    Image(systemName: "minus").font(.system(size: 8, weight: .bold)).frame(width: 12, height: 12)
                }
                .accessibilityLabel("Mais curta")
                .hintVerbatim(String(localized: "Mais curta"), String(localized: "Tira 0,05 s desta sílaba."))
                Text((Double(syllable.centiseconds) / 100).formatted(.number.precision(.fractionLength(2)))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button { update { $0.syllables[index].centiseconds += 5 } } label: {
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold)).frame(width: 12, height: 12)
                }
                .accessibilityLabel("Mais longa")
                .hintVerbatim(String(localized: "Mais longa"), String(localized: "Põe 0,05 s nesta sílaba."))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.small))
    }

    private func update(_ change: (inout KaraokeLine) -> Void) {
        guard var line = KaraokeLine.parse(text.replacingOccurrences(of: "\n", with: "\\N")) else { return }
        change(&line)
        text = line.text.replacingOccurrences(of: "\\N", with: "\n")
        commit()
    }

    private func seconds(_ ms: Int) -> String { (Double(ms) / 1_000).formatted(.number.precision(.fractionLength(2))) + " s" }
}

/// Marking karaoke while the line plays: Return when each syllable starts to be sung.
private struct KaraokeMarkingSheet: View {
    let line: KaraokeLine
    let start: Int
    let end: Int
    let player: PlayerModel
    let apply: (KaraokeLine) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var marks: [Int] = []

    private var current: Int { max(0, marks.count - 1) }
    private var finished: Bool { marks.count >= line.syllables.count || (!marks.isEmpty && !player.isPlaying) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Marcar o karaokê no tempo").font(.title2.weight(.semibold))
            Text("Clique em Começar: a fala toca. Aperte Return (ou Próxima sílaba) no instante em que cada sílaba começa a ser cantada. A primeira começa com a fala; a última vai até o fim dela.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            WrapLayout(spacing: 4) {
                ForEach(Array(line.syllables.enumerated()), id: \.offset) { index, syllable in
                    Text(syllable.text.trimmingCharacters(in: .whitespaces))
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(index == current && !marks.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary),
                                    in: .rect(cornerRadius: Theme.Radius.small))
                        .foregroundStyle(index < marks.count ? .primary : .secondary)
                }
            }
            HStack {
                Button(marks.isEmpty ? "Começar" : "Recomeçar") {
                    marks = [0]
                    player.play(from: start, to: end)
                }
                .hint("Começar", "Toca a fala do início, para marcar as sílabas.")
                Button("Próxima sílaba") { marks.append(max(marks.last ?? 0, min(end - start, player.currentTime - start))) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(marks.isEmpty || marks.count >= line.syllables.count)
                    .hint("Próxima sílaba (Return)", "Marca que a próxima sílaba começa agora.")
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar") {
                    var marked = line
                    marked.setStarts(marks, lineDuration: end - start)
                    apply(marked)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(marks.count < 2 || !finished)
                .hint("Aplicar", "Grava o tempo marcado de cada sílaba nesta fala (⌘Z desfaz).")
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 520)
    }
}
