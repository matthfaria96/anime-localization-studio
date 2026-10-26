import AppKit
import CoreGraphics
import CoreText
import ImageIO
import Foundation
import Testing
@testable import SubtitleKit

/// Minimal PGS writer for tests: white text (palette 1) on transparent (palette 0).
enum PGSWriter {
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

@Suite("PGS bitmap subtitles")
struct PGSTests {
    @Test func decodesCaptionsWithTimes() throws {
        let data = Data(PGSWriter.caption("Hello there", start: 1_000, end: 3_000) + PGSWriter.caption("Second", start: 4_000, end: 6_500))
        let captions = try PGSDecoder.decode(data)
        #expect(captions.count == 2)
        #expect(captions[0].start == 1_000 && captions[0].end == 3_000)
        #expect(captions[1].start == 4_000 && captions[1].end == 6_500)
        #expect(captions[0].image.width == 900 + 32)
        if let path = ProcessInfo.processInfo.environment["ALS_PGS_DUMP"],
           let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, captions[0].image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    @Test func rleRoundTrip() {
        let pixels: [UInt8] = [0, 0, 1, 1, 1, 1, 0, 2] + Array(repeating: 1, count: 70) + Array(repeating: 0, count: 100)
        let width = pixels.count
        #expect(PGSDecoder.decodeRLE(Data(PGSWriter.rle(pixels, width: width, height: 1)), width: width, height: 1) == pixels)
    }

    @Test func recognizesTheTextOnDevice() async throws {
        let data = Data(PGSWriter.caption("I won't let you hurt my friends!", start: 1_000, end: 3_000)
                        + PGSWriter.caption("We have to reach the top floor.", start: 4_000, end: 6_000))
        let (document, skipped) = try await SubtitleOCR().document(fromPGS: data, language: "en-US")
        #expect(skipped == 0)
        #expect(document.count == 2)
        let text = (0..<document.count).map { document.plainText(at: $0) }.joined(separator: " ").lowercased()
        #expect(text.contains("hurt my friends") && text.contains("top floor"), "\(text)")
        #expect(document.cues[1].start == 4_000)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: PGSDecoder.PGSError.self) { try PGSDecoder.decode(Data("1\n00:00".utf8)) }
    }
}
