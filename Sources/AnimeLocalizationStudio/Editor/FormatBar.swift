import AppKit
import SubtitleKit
import SwiftUI

/// Formatting buttons above the line text: italic, bold, underline, strikeout, color and size
/// on the selected stretch (or the whole line), and clearing it, so no tag has to be typed.
struct FormatBar: View {
    /// SubRip markup (`<i>`) instead of ASS tags; SubRip has no font size.
    let html: Bool
    /// The line's style, which color and size come back to after a stretch.
    let style: ASSStyleInfo?
    /// How long the line lasts, to spread a new karaoke over it (ASS only).
    let lineDuration: Int?
    /// Applies a change to the raw text and the selected range (nil = whole line).
    let apply: (@escaping (String, Range<String.Index>?) -> String) -> Void

    private static let colors: [(name: String, color: ASSColor)] = [
        ("Branco", ASSColor(red: 1, green: 1, blue: 1)), ("Amarelo", ASSColor(red: 1, green: 0.88, blue: 0.2)),
        ("Laranja", ASSColor(red: 1, green: 0.55, blue: 0.1)), ("Vermelho", ASSColor(red: 0.93, green: 0.2, blue: 0.2)),
        ("Rosa", ASSColor(red: 1, green: 0.4, blue: 0.7)), ("Roxo", ASSColor(red: 0.62, green: 0.4, blue: 1)),
        ("Azul", ASSColor(red: 0.3, green: 0.6, blue: 1)), ("Verde", ASSColor(red: 0.3, green: 0.85, blue: 0.4)),
        ("Preto", ASSColor(red: 0, green: 0, blue: 0)),
    ]
    private static let sizes: [(name: String, factor: Double)] = [("Bem menor", 0.6), ("Menor", 0.8), ("Maior", 1.25), ("Bem maior", 1.6)]

    var body: some View {
        HStack(spacing: 2) {
            toggle(.italic, "Itálico", "italic", key: "i")
            toggle(.bold, "Negrito", "bold", key: "b")
            toggle(.underline, "Sublinhado", "underline", key: "u")
            toggle(.strikeout, "Riscado", "strikethrough", key: nil)
            Divider().frame(height: 14).padding(.horizontal, 3)
            Menu {
                ForEach(Self.colors, id: \.name) { item in
                    Button { apply { ASSFormatting.color(item.color, restore: style?.primary, in: $0, range: $1, html: html) } } label: {
                        Label { Text(item.name) } icon: { Image(nsImage: Self.swatch(item.color)) }
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hint("Cor", "Pinta o trecho selecionado (ou a fala inteira, sem seleção). Depois do trecho, a cor volta à do estilo.")
            if !html, let style {
                Menu {
                    ForEach(Self.sizes, id: \.name) { item in
                        let size = (style.fontSize * item.factor).rounded()
                        Button("\(item.name) (\(Int(size)))") { apply { ASSFormatting.size(size, restore: style.fontSize, in: $0, range: $1) } }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .hint("Tamanho", "Aumenta ou diminui a letra do trecho selecionado (ou da fala inteira), em relação ao estilo “\(style.name)” (\(Int(style.fontSize))).")
            }
            if !html, let lineDuration {
                Menu {
                    Button("Karaokê por sílaba") { apply { raw, _ in KaraokeLine.make(from: raw, duration: lineDuration, by: .syllable, kind: .fill).text } }
                    Button("Karaokê por palavra") { apply { raw, _ in KaraokeLine.make(from: raw, duration: lineDuration, by: .word, kind: .fill).text } }
                } label: {
                    Image(systemName: "music.mic")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .hint("Karaokê", "Transforma a fala em karaokê: as sílabas (romaji: sa·ka·ra·u) ou as palavras acendem no tempo, com o tempo da fala repartido entre elas. Depois ajuste cada sílaba ou marque no tempo, logo abaixo do texto.")
            }
            Spacer(minLength: 0)
            Button("Limpar formatação", systemImage: "eraser") { apply { ASSFormatting.clear(in: $0, range: $1, html: html) } }
                .labelStyle(.iconOnly)
                .hint("Limpar formatação", "Tira itálico, negrito, cores, tamanho e fonte do trecho selecionado (ou da fala inteira). Posição, tempo e animações ficam.")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func toggle(_ kind: ASSFormatting.Toggle, _ name: String, _ icon: String, key: Character?) -> some View {
        Button(name, systemImage: icon) { apply { ASSFormatting.toggle(kind, in: $0, range: $1, html: html) } }
            .labelStyle(.iconOnly)
            .frame(width: 22)
            .modifier(OptionalShortcut(key: key))
            .hintVerbatim(key.map { "\(name) (⌘\($0.uppercased()))" } ?? name,
                          "Deixa o trecho selecionado em \(name.lowercased()) (ou a fala inteira, sem seleção). Clicar de novo tira.")
    }

    /// The line as it looks on the video, without the codes.
    static func preview(_ raw: String, html: Bool) -> AttributedString {
        var result = AttributedString()
        for run in ASSFormatting.runs(raw.replacingOccurrences(of: "\n", with: "\\N"), html: html) {
            var part = AttributedString(run.text)
            var font = Font.callout
            if run.bold { font = font.bold() }
            if run.italic { font = font.italic() }
            part.font = font
            if run.underline { part.underlineStyle = .single }
            if run.strikeout { part.strikethroughStyle = .single }
            part.foregroundColor = run.color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .white
            result += part
        }
        return result
    }

    /// A colored dot for the menu (menus draw SF Symbols in one color).
    private static func swatch(_ color: ASSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: Character?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(KeyEquivalent(key), modifiers: .command) } else { content }
    }
}
