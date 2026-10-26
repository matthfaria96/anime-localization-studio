import CoreGraphics
import Foundation
import Testing
@testable import ASSRendering

private func script(_ events: String) -> Data {
    Data("""
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,5,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    \(events)

    """.utf8)
}

/// Pixel statistics of a rendered frame: total alpha and alpha-weighted center.
private struct Stats {
    var alpha = 0.0, x = 0.0, y = 0.0, red = 0.0, blue = 0.0

    init(_ image: CGImage?) {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return }
        for row in 0..<image.height {
            for column in 0..<image.width {
                let i = row * image.bytesPerRow + column * 4
                let a = Double(bytes[i + 3])
                alpha += a
                x += Double(column) * a
                y += Double(row) * a
                red += Double(bytes[i])
                blue += Double(bytes[i + 2])
            }
        }
        if alpha > 0 { x /= alpha; y /= alpha }
    }
}

@Suite("libass rendering")
struct ASSRendererTests {
    @Test func fadeChangesOpacityOverTime() async throws {
        let renderer = try ASSRenderer()
        try await renderer.load(script: script(#"Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,{\fad(1000,0)}Fade in"#))
        let early = Stats(await renderer.render(at: 100, width: 640, height: 360, videoWidth: 640, videoHeight: 360))
        let late = Stats(await renderer.render(at: 2_000, width: 640, height: 360, videoWidth: 640, videoHeight: 360))
        #expect(late.alpha > 0)
        #expect(early.alpha < late.alpha * 0.3, "early \(early.alpha) late \(late.alpha)")
    }

    @Test func moveAnimatesPosition() async throws {
        let renderer = try ASSRenderer()
        try await renderer.load(script: script(#"Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\an5\move(100,180,540,180)}X"#))
        let start = Stats(await renderer.render(at: 0, width: 640, height: 360, videoWidth: 640, videoHeight: 360))
        let end = Stats(await renderer.render(at: 1_990, width: 640, height: 360, videoWidth: 640, videoHeight: 360))
        #expect(abs(start.x - 100) < 25, "start x \(start.x)")
        #expect(abs(end.x - 540) < 25, "end x \(end.x)")
        #expect(abs(start.y - 180) < 25)
    }

    @Test func drawsVectorShapesAndScalesToTheFrame() async throws {
        let renderer = try ASSRenderer()
        try await renderer.load(script: script(#"Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\an7\pos(0,0)\p1}m 0 0 l 320 0 320 180 0 180{\p0}"#))
        let small = Stats(await renderer.render(at: 500, width: 640, height: 360, videoWidth: 640, videoHeight: 360))
        #expect(abs(small.x - 160) < 6 && abs(small.y - 90) < 6, "\(small.x),\(small.y)")
        // Same script in a frame twice as large: the shape scales with it.
        let large = Stats(await renderer.render(at: 500, width: 1280, height: 720, videoWidth: 1280, videoHeight: 720))
        #expect(abs(large.x - 320) < 10 && abs(large.y - 180) < 10, "\(large.x),\(large.y)")
    }

    @Test func karaokeFillsSyllablesOverTime() async throws {
        let renderer = try ASSRenderer()
        // Primary white, secondary (unsung) &H000000FF = pure red (ASS colors are BGR): \k turns each sung syllable white, so blue appears.
        // A leading empty syllable delays the song by 1 s, so at 10 ms nothing is sung yet.
        try await renderer.load(script: script(#"Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\k100}{\k100}Ka{\k100}ra"#))
        let before = Stats(await renderer.render(at: 10, width: 640, height: 360, videoWidth: 640, videoHeight: 360))
        let after = Stats(await renderer.render(at: 3_000, width: 640, height: 360, videoWidth: 640, videoHeight: 360))
        #expect(after.blue > before.blue * 2 + 1_000, "blue before \(before.blue) after \(after.blue)")
    }

    @Test func nothingOutsideTheLineTime() async throws {
        let renderer = try ASSRenderer()
        try await renderer.load(script: script("Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi"))
        #expect(await renderer.render(at: 3_000, width: 640, height: 360, videoWidth: 640, videoHeight: 360) == nil)
    }
}
