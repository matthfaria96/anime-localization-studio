import SubtitleKit
import SwiftUI

/// Approximate preview of the active lines over the video: style font, size, colors, outline,
/// numpad alignment (`\an`), `\pos`, margins and the script's reference resolution. Animated
/// tags (`\t`, `\move`, `\fad`), karaoke, drawings and clips are not rendered here; exports are
/// never affected by this preview.
struct SubtitleOverlay: View {
    let cues: [SubtitleCue]
    let document: SubtitleDocument?
    let videoRect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cues) { cue in
                CueView(cue: cue, layout: layout(for: cue))
            }
        }
        .frame(width: videoRect.width, height: videoRect.height, alignment: .topLeading)
        .offset(x: videoRect.minX, y: videoRect.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct Layout {
        var style: ASSStyleInfo
        var scale: Double
        var alignment: Int
        var position: CGPoint?
        var margins: EdgeInsets
    }

    private func layout(for cue: SubtitleCue) -> Layout {
        guard case .ass(let ass) = document else {
            let scale = videoRect.height / 360
            return Layout(style: .fallback, scale: scale, alignment: ASSText.alignmentOverride(in: cue.rawText) ?? 2, position: nil,
                          margins: EdgeInsets(top: 20 * scale, leading: 20 * scale, bottom: 20 * scale, trailing: 20 * scale))
        }
        let style = ass.style(named: cue.style).map { ASSStyleInfo(record: $0, isSSA: ass.isSSA) } ?? .fallback
        let resolution = ass.playResolution
        let scale = videoRect.height / resolution.height
        let scaleX = videoRect.width / resolution.width
        let position = ASSText.positionOverride(in: cue.rawText).map { CGPoint(x: $0.x * scaleX, y: $0.y * scale) }
        return Layout(style: style, scale: scale, alignment: ASSText.alignmentOverride(in: cue.rawText) ?? style.alignment, position: position,
                      margins: EdgeInsets(top: style.marginV * scale, leading: style.marginL * scaleX, bottom: style.marginV * scale, trailing: style.marginR * scaleX))
    }
}

private struct CueView: View {
    let cue: SubtitleCue
    let layout: SubtitleOverlay.Layout

    var body: some View {
        GeometryReader { proxy in
            let text = styledText
            let anchorX = horizontalAnchor
            let anchorY = verticalAnchor
            if let position = layout.position {
                text.fixedSize()
                    .alignmentGuide(.leading) { d in d.width * anchorX }
                    .alignmentGuide(.top) { d in d.height * anchorY }
                    .offset(x: position.x, y: position.y)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                text
                    .padding(layout.margins)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: frameAlignment)
            }
        }
    }

    private var styledText: some View {
        let style = layout.style
        let size = max(8, style.fontSize * layout.scale)
        let outline = max(0.6, style.outline * layout.scale * 0.7)
        let fill = Color(.sRGB, red: style.primary.red, green: style.primary.green, blue: style.primary.blue, opacity: max(0.15, style.primary.opacity))
        let stroke = Color(.sRGB, red: style.outlineColor.red, green: style.outlineColor.green, blue: style.outlineColor.blue, opacity: style.outlineColor.opacity)
        return Text(cue.plainText)
            .font(.custom(style.fontName, size: size).weight(style.bold ? .bold : .regular))
            .italic(style.italic)
            .foregroundStyle(fill)
            .multilineTextAlignment(textAlignment)
            .shadow(color: stroke, radius: outline * 0.5)
            .shadow(color: stroke, radius: outline * 0.5)
            .shadow(color: stroke, radius: outline)
            .shadow(color: .black.opacity(style.shadow > 0 ? 0.55 : 0), radius: 0, x: style.shadow * layout.scale, y: style.shadow * layout.scale)
    }

    // Numpad: 1 2 3 bottom, 4 5 6 middle, 7 8 9 top.
    private var column: Int { (layout.alignment - 1) % 3 }
    private var row: Int { (layout.alignment - 1) / 3 }
    private var horizontalAnchor: CGFloat { [0, 0.5, 1][column] }
    private var verticalAnchor: CGFloat { [1, 0.5, 0][row] }
    private var textAlignment: TextAlignment { [.leading, .center, .trailing][column] }
    private var frameAlignment: Alignment {
        let h: [HorizontalAlignment] = [.leading, .center, .trailing]
        let v: [VerticalAlignment] = [.bottom, .center, .top]
        return Alignment(horizontal: h[column], vertical: v[row])
    }
}
