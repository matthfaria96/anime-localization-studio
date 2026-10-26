import ASSRendering
import SwiftUI

/// Draws the subtitle frame libass renders for the current time over the video rectangle, at
/// the display's pixel density (capped at the video's own resolution).
struct LibassOverlay: View {
    let renderer: ASSRenderer
    let time: Int
    let revision: Int
    let videoRect: CGRect
    let videoSize: CGSize
    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    private struct Key: Hashable { let time: Int, width: Int, height: Int, revision: Int }

    private var pixelSize: (Int, Int) {
        let scale = min(displayScale, max(1, videoSize.width / max(1, videoRect.width)))
        return (Int(videoRect.width * scale), Int(videoRect.height * scale))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .offset(x: videoRect.minX, y: videoRect.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: Key(time: time, width: pixelSize.0, height: pixelSize.1, revision: revision)) {
            let (width, height) = pixelSize
            image = await renderer.render(at: time, width: width, height: height,
                                          videoWidth: Int(videoSize.width), videoHeight: Int(videoSize.height))
        }
    }
}
