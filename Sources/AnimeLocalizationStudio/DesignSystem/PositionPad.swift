import SwiftUI

/// Where a subtitle line shows on screen, as the 3×3 numpad ASS uses (7 8 9 top, 4 5 6 middle,
/// 1 2 3 bottom).
enum ScreenPosition {
    static let rows = [[7, 8, 9], [4, 5, 6], [1, 2, 3]]

    /// The area a point (fraction of the frame) falls in, by thirds.
    static func area(of point: CGPoint) -> Int {
        let column = min(2, max(0, Int(point.x * 3))), row = min(2, max(0, Int(point.y * 3)))
        return (2 - row) * 3 + column + 1
    }

    static func name(_ alignment: Int) -> String {
        let vertical = alignment >= 7 ? String(localized: "Em cima") : alignment >= 4 ? String(localized: "No meio") : String(localized: "Embaixo")
        let horizontal = [String(localized: "à esquerda"), String(localized: "no centro"), String(localized: "à direita")][(alignment - 1) % 3]
        return "\(vertical), \(horizontal)"
    }
}

/// Nine buttons laid out like the screen. The area the line is in is filled with the accent
/// color; a line at a free point (`\pos`, or margins that put it elsewhere) fills none and
/// shows a dot where it really is.
struct PositionPad: View {
    /// The area the line is in, or nil when it is at a free point.
    let alignment: Int?
    /// Where the line is, as a fraction of the frame, drawn when it is at a free point.
    let point: CGPoint?
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
                        .hintVerbatim(ScreenPosition.name(value), String(localized: "Coloca esta fala \(ScreenPosition.name(value).lowercased()) da tela."))
                    }
                }
            }
        }
        .overlay { PointDot(point: alignment == nil ? point : nil, size: 7) }
        .padding(4)
        .background(.background.secondary, in: .rect(cornerRadius: 6))
    }
}

/// A tiny 3×3 picture of the position, for the line list. Bottom center (the usual place) is drawn
/// faint so the lines placed elsewhere stand out; a line at a free point shows only a dot.
struct PositionGlyph: View {
    let alignment: Int?
    let fromLine: Bool
    var point: CGPoint?

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
        .overlay { PointDot(point: alignment == nil ? point : nil, size: 3.5) }
        .accessibilityLabel(alignment.map(ScreenPosition.name) ?? String(localized: "Ponto livre"))
    }

    private var isUsual: Bool { alignment == 2 && !fromLine }
}

/// The dot that marks where a line at a free point really is.
private struct PointDot: View {
    let point: CGPoint?
    let size: CGFloat

    var body: some View {
        GeometryReader { proxy in
            if let point {
                Circle()
                    .fill(.tint)
                    .overlay(Circle().strokeBorder(.background, lineWidth: size > 4 ? 1.5 : 0.5))
                    .frame(width: size, height: size)
                    .position(x: min(1, max(0, point.x)) * proxy.size.width, y: min(1, max(0, point.y)) * proxy.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}
