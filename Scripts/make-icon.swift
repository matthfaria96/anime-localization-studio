// Draws the 1024×1024 app icon: two overlapping speech bubbles (Japanese “あ” → Latin “A”)
// on a deep indigo field with a sakura glow.  Usage: swift Scripts/make-icon.swift <out.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

// Squircle-ish rounded square with the macOS grid margin (100 px).
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0.10, 0.07, 0.22))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0.24, 0.13, 0.45), color(0.08, 0.06, 0.20)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: size / 2, y: tile.maxY), end: CGPoint(x: size / 2, y: tile.minY), options: [])
let glow = CGGradient(colorsSpace: space, colors: [color(1.0, 0.36, 0.56, 0.55), color(1.0, 0.36, 0.56, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 340, y: 640), startRadius: 0, endCenter: CGPoint(x: 340, y: 640), endRadius: 520, options: [])
ctx.restoreGState()

func bubble(_ rect: CGRect, tailLeft: Bool) -> CGPath {
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: 96, cornerHeight: 96)
    let baseX = tailLeft ? rect.minX + 110 : rect.maxX - 110
    let tipX = tailLeft ? rect.minX + 40 : rect.maxX - 40
    path.move(to: CGPoint(x: baseX - 46, y: rect.minY + 8))
    path.addLine(to: CGPoint(x: tipX, y: rect.minY - 92))
    path.addLine(to: CGPoint(x: baseX + 46, y: rect.minY + 8))
    path.closeSubpath()
    return path
}

func drawGlyph(_ text: String, font: NSFont, color fill: NSColor, center: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fill]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, ctx)
}

// Back bubble: sakura, “あ”.
let back = CGRect(x: 196, y: 470, width: 420, height: 330)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.30))
ctx.addPath(bubble(back, tailLeft: true))
let sakura = CGGradient(colorsSpace: space, colors: [color(1.0, 0.47, 0.64), color(0.90, 0.26, 0.48)] as CFArray, locations: [0, 1])!
ctx.clip()
ctx.drawLinearGradient(sakura, start: CGPoint(x: 0, y: back.maxY), end: CGPoint(x: 0, y: back.minY - 100), options: [])
ctx.restoreGState()
drawGlyph("あ", font: NSFont(name: "Hiragino Maru Gothic ProN W4", size: 220) ?? .systemFont(ofSize: 220, weight: .bold),
          color: .white, center: CGPoint(x: back.midX, y: back.midY + 6))

// Front bubble: white glass, “A”.
let front = CGRect(x: 420, y: 250, width: 410, height: 320)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.38))
ctx.addPath(bubble(front, tailLeft: false))
ctx.setFillColor(color(0.98, 0.97, 1.0))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bubble(front, tailLeft: false))
ctx.clip()
let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0), color(0.86, 0.84, 0.95, 0.9)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: front.maxY), end: CGPoint(x: 0, y: front.minY - 90), options: [])
ctx.restoreGState()
drawGlyph("A", font: .systemFont(ofSize: 230, weight: .heavy), color: NSColor(red: 0.20, green: 0.11, blue: 0.42, alpha: 1),
          center: CGPoint(x: front.midX, y: front.midY + 4))

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil) else { fatalError("image") }
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output)")
