import SwiftUI

/// Where a subtitle line shows on screen, as the 3×3 numpad ASS uses (7 8 9 top, 4 5 6 middle,
/// 1 2 3 bottom).
enum ScreenPosition {
    static let rows = [[7, 8, 9], [4, 5, 6], [1, 2, 3]]

    static func name(_ alignment: Int) -> String {
        let vertical = alignment >= 7 ? "Em cima" : alignment >= 4 ? "No meio" : "Embaixo"
        let horizontal = ["à esquerda", "no centro", "à direita"][(alignment - 1) % 3]
        return "\(vertical), \(horizontal)"
    }
}

/// Nine buttons laid out like the screen; the current position is filled with the accent color.
struct PositionPad: View {
    let alignment: Int
    let select: (Int) -> Void

    var body: some View {
        VStack(spacing: 3) {
            ForEach(ScreenPosition.rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { value in
                        Button { select(value) } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(value == alignment ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                                .frame(width: 26, height: 16)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ScreenPosition.name(value))
                        .accessibilityAddTraits(value == alignment ? .isSelected : [])
                        .hintVerbatim(ScreenPosition.name(value), "Coloca esta fala \(ScreenPosition.name(value).lowercased()) da tela.")
                    }
                }
            }
        }
        .padding(4)
        .background(.background.secondary, in: .rect(cornerRadius: 6))
    }
}

/// A tiny 3×3 picture of the position, for the line list. Bottom center (the usual place) is drawn
/// faint so the lines placed elsewhere stand out.
struct PositionGlyph: View {
    let alignment: Int
    let fromLine: Bool

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(ScreenPosition.rows, id: \.self) { row in
                HStack(spacing: 1.5) {
                    ForEach(row, id: \.self) { value in
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(value == alignment ? (isUsual ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)) : AnyShapeStyle(.quaternary))
                            .frame(width: 3.5, height: 2.5)
                    }
                }
            }
        }
        .accessibilityLabel(ScreenPosition.name(alignment))
    }

    private var isUsual: Bool { alignment == 2 && !fromLine }
}
