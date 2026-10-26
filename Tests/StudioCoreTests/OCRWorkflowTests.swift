import AppKit
import CoreGraphics
import CoreText
import Foundation
import MediaKit
import SubtitleKit
import Testing
import TranslationKit
@testable import StudioCore

/// Minimal PGS writer for tests: white text (palette 1) on transparent (palette 0).
enum TestPGSWriter {
    static func segment(_ type: UInt8, pts: Int, _ body: [UInt8]) -> [UInt8] {
        let t = UInt32(pts * 90)
        return [0x50, 0x47, UInt8(t >> 24), UInt8(t >> 16 & 0xFF), UInt8(t >> 8 & 0xFF), UInt8(t & 0xFF), 0, 0, 0, 0,
                type, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func render(_ text: String) -> (width: Int, height: Int, pixels: [UInt8]) {
        let width = 900, height = 90
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 54, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
        context.textPosition = CGPoint(x: 20, y: 22)
        CTLineDraw(line, context)
        // The bitmap context's memory is already top row first, like PGS.
        return (width, height, pixels.map { $0 > 127 ? 1 : 0 })
    }

    static func rle(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for row in 0..<height {
            var x = 0
            while x < width {
                let color = pixels[row * width + x]
                var run = 1
                while x + run < width, pixels[row * width + x + run] == color, run < 16_383 { run += 1 }
                if color == 0 {
                    out += run < 64 ? [0, UInt8(run)] : [0, UInt8(0x40 | run >> 8), UInt8(run & 0xFF)]
                } else if run < 3 {
                    out += Array(repeating: color, count: run)
                } else {
                    out += run < 64 ? [0, UInt8(0x80 | run), color] : [0, UInt8(0xC0 | run >> 8), UInt8(run & 0xFF), color]
                }
                x += run
            }
            out += [0, 0]
        }
        return out
    }

    static func caption(_ text: String, start: Int, end: Int) -> [UInt8] {
        let (w, h, pixels) = render(text)
        let data = rle(pixels, width: w, height: h)
        let pcs = be16(1920) + be16(1080) + [0x10] + be16(1) + [0x80, 0, 0, 1] + be16(0) + [0, 0] + be16(500) + be16(900)
        let pds: [UInt8] = [0, 0] + [1, 235, 128, 128, 255]
        let length = data.count + 4
        let ods = be16(0) + [0, 0xC0] + [UInt8(length >> 16), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + be16(w) + be16(h) + data
        let clear = be16(1920) + be16(1080) + [0x10] + be16(2) + [0x00, 0, 0, 0]
        return segment(0x16, pts: start, pcs) + segment(0x14, pts: start, pds) + segment(0x15, pts: start, ods) + segment(0x80, pts: start, [])
            + segment(0x16, pts: end, clear) + segment(0x80, pts: end, [])
    }
}


private let ocrTools = ToolLocator()

@Suite("Bitmap subtitle OCR workflow (real tools)", .enabled(if: [ExternalTool.mkvmerge, .mkvextract, .ffmpeg].allSatisfy { ocrTools.locate($0) != nil }))
struct OCRWorkflowTests {
    @Test func recognizesAnEmbeddedPGSTrack() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSOcr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let video = base.appendingPathComponent("v.mkv")
        try await ProcessRunner.runChecked(try ocrTools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=7",
                                                                           "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", video.path])
        let sup = base.appendingPathComponent("en.sup")
        try Data(TestPGSWriter.caption("I won't let you hurt my friends!", start: 1_000, end: 3_000)
                 + TestPGSWriter.caption("We have to reach the top floor.", start: 4_000, end: 6_000)).write(to: sup)
        let episode = base.appendingPathComponent("Movie.mkv")
        try await ProcessRunner.runChecked(try ocrTools.require(.mkvmerge), ["-o", episode.path, video.path, "--language", "0:en", sup.path], acceptedExitCodes: [0, 1])
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: AppleTranslationEngine(), glossary: Glossary())
        await #expect(throws: WorkflowError.self) { _ = try await workflow.prepareSource(ProjectStore(paths: paths).project(for: episode)) }
        let (project, skipped) = try await workflow.recognizeBitmapSubtitle(ProjectStore(paths: paths).project(for: episode), language: "en-US") { _ in }
        #expect(skipped == 0)
        let (_, _, source) = try await workflow.prepareSource(project)
        let document = try SubtitleDocument.load(source)
        #expect(document.count == 2)
        #expect(document.plainText(at: 1).lowercased().contains("top floor"))
        #expect(document.cues[0].start == 1_000 && document.cues[0].end == 3_000)
    }
}
