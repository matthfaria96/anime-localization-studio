import SubtitleKit
import SwiftUI

/// The handle that moves the selected line on the video: drag it and the line goes to that
/// exact point (`\pos`). Shown only for one selected line that is on screen while paused,
/// in ASS (SRT has no exact points) and when the line is not animated with `\move`.
struct PositionHandle: View {
    @Bindable var workspace: WorkspaceModel
    let rect: CGRect
    @State private var drag: CGSize?
    @Environment(\.undoManager) private var undoManager

    private var editor: EditorModel { workspace.editor }

    var body: some View {
        if let index = editor.selection.count == 1 ? editor.selection.first : nil,
           let row = editor.rows.first(where: { $0.id == index }),
           !workspace.player.isPlaying, (row.start..<row.end).contains(workspace.player.currentTime),
           editor.canPlace(index), let frame = editor.playResolution, let anchor = editor.anchor(of: index), rect.width > 0 {
            let scale = CGSize(width: rect.width / frame.width, height: rect.height / frame.height)
            let start = CGPoint(x: rect.minX + anchor.x * scale.width, y: rect.minY + anchor.y * scale.height)
            let point = CGPoint(x: start.x + (drag?.width ?? 0), y: start.y + (drag?.height ?? 0))
            ZStack {
                if drag != nil {
                    Path { path in path.move(to: start); path.addLine(to: point) }
                        .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    Text("\(Int(target(anchor, scale).x)), \(Int(target(anchor, scale).y))")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: .capsule)
                        .foregroundStyle(.white)
                        .position(x: point.x, y: point.y - 26)
                }
                knob
                    .position(point)
                    .onTapGesture {}
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag = $0.translation }
                            .onEnded { value in
                                drag = value.translation
                                editor.setPosition(target(anchor, scale), line: index, undoManager: undoManager)
                                drag = nil
                            }
                    )
                    .hint("Mover a fala", "Arraste para pôr a fala em qualquer ponto do vídeo. Ela passa a ter um ponto exato (\\pos); ⌘Z desfaz e “Usar a do estilo” no painel da fala volta ao normal.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The dragged point in script coordinates.
    private func target(_ anchor: ASSPoint, _ scale: CGSize) -> ASSPoint {
        ASSPoint(x: (anchor.x + (drag?.width ?? 0) / scale.width).rounded(), y: (anchor.y + (drag?.height ?? 0) / scale.height).rounded())
    }

    private var knob: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.accentColor.opacity(drag == nil ? 0.7 : 1), in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            .contentShape(.circle)
            .pointerStyle(.grabIdle)
    }
}
