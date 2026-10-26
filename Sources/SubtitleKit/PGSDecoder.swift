import CoreGraphics
import Foundation

/// Decoder for Blu-ray PGS subtitles (`.sup`, Matroska `S_HDMV/PGS`): bitmap captions made of
/// segments — presentation composition (PCS), palette (PDS, YCbCr + alpha), objects (ODS,
/// run-length encoded) — grouped in display sets that show or clear the screen.
public enum PGSDecoder {
    public struct Caption: Sendable {
        public let start: Int
        public var end: Int
        /// The composed caption (all objects of the display set) as an 8-bit grayscale image with
        /// dark text on white, which is what text recognition reads best.
        public let image: CGImage
    }

    public enum PGSError: Error, LocalizedError {
        case notPGS
        public var errorDescription: String? { "O arquivo não é uma legenda PGS válida." }
    }

    private struct Object { var width = 0, height = 0, data = Data() }
    private struct Placement { let objectID: Int; let x: Int; let y: Int }

    public static func decode(_ data: Data) throws -> [Caption] {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x50, bytes[1] == 0x47 else { throw PGSError.notPGS }
        var captions: [Caption] = []
        var palette = [UInt8: (y: UInt8, alpha: UInt8)]()
        var objects: [Int: Object] = [:]
        var placements: [Placement] = []
        var screen = (width: 1920, height: 1080)
        var setStart = 0
        var offset = 0
        while offset + 13 <= bytes.count {
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x47 else { break }
            let pts = Int(UInt32(bytes[offset + 2]) << 24 | UInt32(bytes[offset + 3]) << 16 | UInt32(bytes[offset + 4]) << 8 | UInt32(bytes[offset + 5]))
            let type = bytes[offset + 10]
            let size = Int(bytes[offset + 11]) << 8 | Int(bytes[offset + 12])
            let body = offset + 13
            guard body + size <= bytes.count else { break }
            let segment = Array(bytes[body..<(body + size)])
            let time = pts / 90
            switch type {
            case 0x16 where segment.count >= 11:  // PCS
                screen = (Int(segment[0]) << 8 | Int(segment[1]), Int(segment[2]) << 8 | Int(segment[3]))
                // A new composition ends the caption on screen.
                if var last = captions.last, last.end <= last.start { last.end = time; captions[captions.count - 1] = last }
                setStart = time
                placements = []
                let count = Int(segment[10])
                var p = 11
                for _ in 0..<count where p + 8 <= segment.count {
                    let id = Int(segment[p]) << 8 | Int(segment[p + 1])
                    let cropped = segment[p + 3] & 0x40 != 0
                    placements.append(Placement(objectID: id, x: Int(segment[p + 4]) << 8 | Int(segment[p + 5]), y: Int(segment[p + 6]) << 8 | Int(segment[p + 7])))
                    p += cropped ? 16 : 8
                }
            case 0x14 where segment.count >= 2:  // PDS
                var p = 2
                while p + 5 <= segment.count {
                    palette[segment[p]] = (segment[p + 1], segment[p + 4])
                    p += 5
                }
            case 0x15 where segment.count >= 4:  // ODS
                let id = Int(segment[0]) << 8 | Int(segment[1])
                let first = segment[3] & 0x80 != 0
                if first, segment.count >= 11 {
                    var object = Object()
                    object.width = Int(segment[7]) << 8 | Int(segment[8])
                    object.height = Int(segment[9]) << 8 | Int(segment[10])
                    object.data = Data(segment[11...])
                    objects[id] = object
                } else {
                    objects[id]?.data.append(contentsOf: segment[4...])
                }
            case 0x80:  // END: render the display set
                // `break`, not `continue`: the offset below must still advance past this segment.
                guard !placements.isEmpty, let image = compose(placements, objects: objects, palette: palette, screen: screen) else { break }
                captions.append(Caption(start: setStart, end: setStart, image: image))
            default:
                break
            }
            offset = body + size
        }
        // A caption never cleared lasts a few seconds.
        if var last = captions.last, last.end <= last.start { last.end = last.start + 4_000; captions[captions.count - 1] = last }
        return captions
    }

    /// Crops to the objects' bounding box (plus a margin) and draws luminance × alpha as ink.
    private static func compose(_ placements: [Placement], objects: [Int: Object], palette: [UInt8: (y: UInt8, alpha: UInt8)],
                                screen: (width: Int, height: Int)) -> CGImage? {
        let decoded = placements.compactMap { placement -> (Placement, Object, [UInt8])? in
            guard let object = objects[placement.objectID], object.width > 0, object.height > 0 else { return nil }
            return (placement, object, decodeRLE(object.data, width: object.width, height: object.height))
        }
        guard !decoded.isEmpty else { return nil }
        let margin = 16
        let minX = decoded.map { $0.0.x }.min()! - margin, minY = decoded.map { $0.0.y }.min()! - margin
        let maxX = decoded.map { $0.0.x + $0.1.width }.max()! + margin, maxY = decoded.map { $0.0.y + $0.1.height }.max()! + margin
        let width = maxX - minX, height = maxY - minY
        var pixels = [UInt8](repeating: 255, count: width * height)
        for (placement, object, indices) in decoded {
            for row in 0..<object.height {
                for column in 0..<object.width {
                    guard let entry = palette[indices[row * object.width + column]], entry.alpha > 0 else { continue }
                    // Bright, opaque pixels (the letters) become dark ink; dark outlines stay light.
                    let ink = Int(entry.y) * Int(entry.alpha) / 255
                    let target = (placement.y - minY + row) * width + (placement.x - minX + column)
                    pixels[target] = UInt8(max(0, 255 - ink))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PGS run-length encoding: a non-zero byte is one pixel; `00 00` ends a line; otherwise the
    /// flags of the second byte give a run of color 0 or of the color in the following byte.
    static func decodeRLE(_ data: Data, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let bytes = [UInt8](data)
        var i = 0, x = 0, y = 0
        func put(_ color: UInt8, _ count: Int) {
            for _ in 0..<count where x < width && y < height {
                pixels[y * width + x] = color
                x += 1
            }
        }
        while i < bytes.count, y < height {
            let b = bytes[i]; i += 1
            if b != 0 { put(b, 1); continue }
            guard i < bytes.count else { break }
            let flags = bytes[i]; i += 1
            if flags == 0 { x = 0; y += 1; continue }
            var length = Int(flags & 0x3F)
            if flags & 0x40 != 0, i < bytes.count { length = length << 8 | Int(bytes[i]); i += 1 }
            var color: UInt8 = 0
            if flags & 0x80 != 0, i < bytes.count { color = bytes[i]; i += 1 }
            put(color, length)
        }
        return pixels
    }
}
