import CLibass
import CoreGraphics
import Foundation

/// Renders ASS/SSA exactly like mpv, VLC and Aegisub do, through libass (ISC): animations
/// (`\t`, `\move`, `\fad`), karaoke, vector drawings, clips, rotations, blur, borders, and the
/// fonts embedded in the MKV. Frames come out as transparent images to lay over the video.
///
/// libass is not thread-safe, so all work happens inside this actor.
public actor ASSRenderer {
    // Only touched inside the actor, and by `deinit` once nothing else can reach it.
    nonisolated(unsafe) private let library: OpaquePointer
    nonisolated(unsafe) private let renderer: OpaquePointer
    nonisolated(unsafe) private var track: UnsafeMutablePointer<ASS_Track>?
    private var lastImage: CGImage?
    private var lastSize: (Int, Int) = (0, 0)

    public init() throws {
        guard let library = ass_library_init() else { throw RendererError.unavailable }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            throw RendererError.unavailable
        }
        // Silence libass's diagnostics (they go to stderr by default).
        ass_set_message_cb(library, { _, _, _, _ in }, nil)
        // CoreText font provider: every font installed on the Mac, plus the embedded ones.
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        self.library = library
        self.renderer = renderer
    }

    deinit {
        if let track { ass_free_track(track) }
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    public enum RendererError: Error, LocalizedError {
        case unavailable
        case unreadableScript

        public var errorDescription: String? {
            switch self {
            case .unavailable: "O renderizador libass não pôde ser iniciado."
            case .unreadableScript: "O libass não conseguiu ler a legenda."
            }
        }
    }

    /// Registers a font file (an MKV attachment) under its file name.
    public func addFont(named name: String, data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ass_add_font(library, name, base, Int32(buffer.count))
        }
        // Make the renderer see the new font.
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
    }

    /// Replaces the script being rendered (call again after edits).
    public func load(script: Data) throws {
        var bytes = [CChar](repeating: 0, count: script.count + 1)
        script.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(&bytes, base, script.count) }
        }
        guard let newTrack = ass_read_memory(library, &bytes, script.count, nil) else { throw RendererError.unreadableScript }
        if let track { ass_free_track(track) }
        track = newTrack
        lastImage = nil
    }

    /// The overlay at `milliseconds` for a frame of `width × height` pixels showing a video of
    /// `videoWidth × videoHeight` (the storage size libass uses for aspect and scaling).
    /// Returns `nil` when nothing is on screen.
    public func render(at milliseconds: Int, width: Int, height: Int, videoWidth: Int, videoHeight: Int) -> CGImage? {
        guard let track, width > 0, height > 0 else { return nil }
        ass_set_frame_size(renderer, Int32(width), Int32(height))
        ass_set_storage_size(renderer, Int32(max(1, videoWidth)), Int32(max(1, videoHeight)))
        var change: Int32 = 0
        let images = ass_render_frame(renderer, track, Int64(milliseconds), &change)
        if change == 0, lastSize == (width, height) { return lastImage }
        lastSize = (width, height)
        lastImage = images.flatMap { Self.composite($0, width: width, height: height) }
        return lastImage
    }

    /// Blends libass's alpha masks (one color each) into a premultiplied RGBA image.
    static func composite(_ first: UnsafeMutablePointer<ASS_Image>, width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var node: UnsafeMutablePointer<ASS_Image>? = first
        pixels.withUnsafeMutableBufferPointer { out in
            while let image = node?.pointee {
                defer { node = image.next }
                guard image.w > 0, image.h > 0, let bitmap = image.bitmap else { continue }
                let color = image.color
                let r = Int(color >> 24 & 0xFF), g = Int(color >> 16 & 0xFF), b = Int(color >> 8 & 0xFF)
                let opacity = 255 - Int(color & 0xFF)
                for row in 0..<Int(image.h) {
                    let y = Int(image.dst_y) + row
                    guard y >= 0, y < height else { continue }
                    for column in 0..<Int(image.w) {
                        let x = Int(image.dst_x) + column
                        guard x >= 0, x < width else { continue }
                        let coverage = Int(bitmap[row * Int(image.stride) + column]) * opacity / 255
                        guard coverage > 0 else { continue }
                        let i = (y * width + x) * 4
                        let keep = 255 - coverage
                        out[i] = UInt8((r * coverage + Int(out[i]) * keep) / 255)
                        out[i + 1] = UInt8((g * coverage + Int(out[i + 1]) * keep) / 255)
                        out[i + 2] = UInt8((b * coverage + Int(out[i + 2]) * keep) / 255)
                        out[i + 3] = UInt8(coverage + Int(out[i + 3]) * keep / 255)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
