import Foundation

/// A point in the script's own coordinates (`PlayResX` × `PlayResY`), as `\pos` uses them.
public struct ASSPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

extension ASSText {
    private static let posPattern = #"\\pos\(\s*-?[\d.]+\s*,\s*-?[\d.]+\s*\)"#

    /// The line placed at an exact point (`\pos(x,y)`), or with every `\pos` removed when nil.
    /// An existing `\pos` is replaced where it is; otherwise the tag goes at the end of the
    /// leading override block (or in a new one). Nothing else in the text changes.
    public static func settingPosition(_ point: (x: Double, y: Double)?, in text: String) -> String {
        guard let point else {
            return text.replacingOccurrences(of: posPattern, with: "", options: .regularExpression).replacingOccurrences(of: "{}", with: "")
        }
        let tag = "\\pos(\(number(point.x)),\(number(point.y)))"
        if let range = text.range(of: posPattern, options: .regularExpression) { return text.replacingCharacters(in: range, with: tag) }
        if case .override(let block) = tokenize(text).first, block.contains("\\") {
            return String(block.dropLast()) + tag + "}" + text.dropFirst(block.count)
        }
        return "{\(tag)}" + text
    }

    /// The line moves on its own (`\move`): its position is an animation, not one point.
    public static func hasMovement(_ text: String) -> Bool {
        text.range(of: #"\\move\("#, options: .regularExpression) != nil
    }

    /// The starting point of a `\move(x1,y1,x2,y2…)`.
    public static func movementStart(in text: String) -> (x: Double, y: Double)? {
        guard let range = text.range(of: #"\\move\(\s*-?[\d.]+\s*,\s*-?[\d.]+"#, options: .regularExpression) else { return nil }
        let numbers = text[range].dropFirst(6).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }

    /// The numpad area (1–9) a point falls in, by thirds of the frame (7 8 9 top … 1 2 3 bottom).
    public static func area(of point: ASSPoint, in frame: (width: Double, height: Double)) -> Int {
        let column = min(2, max(0, Int(point.x / max(1, frame.width) * 3)))
        let row = min(2, max(0, Int(point.y / max(1, frame.height) * 3)))
        return (2 - row) * 3 + column + 1
    }

    /// Whole numbers without decimals, others with one (`\pos(640,360.5)`).
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

extension ASSDocument {
    /// Where an event is anchored on screen, in script coordinates: its `\pos` (or where its
    /// `\move` starts), or the point libass places it at from the alignment (the line's `\an`
    /// or its style's) and the margins (the line's own when not zero, else the style's).
    public func anchor(ofEvent index: Int) -> ASSPoint {
        let event = event(at: index)
        if let pos = ASSText.positionOverride(in: event.text) ?? ASSText.movementStart(in: event.text) { return ASSPoint(x: pos.x, y: pos.y) }
        let style = style(named: event.styleName).map { ASSStyleInfo(record: $0, isSSA: isSSA) } ?? ASSStyleInfo.fallback
        let alignment = ASSText.alignmentOverride(in: event.text) ?? style.alignment
        func margin(_ name: String, _ fallback: Double) -> Double {
            let own = event[name].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            return own != 0 ? own : fallback
        }
        let (width, height) = playResolution
        let left = margin("MarginL", style.marginL), right = margin("MarginR", style.marginR), vertical = margin("MarginV", style.marginV)
        let x: Double = switch (alignment - 1) % 3 {
        case 0: left
        case 1: (left + width - right) / 2
        default: width - right
        }
        let y: Double = switch (alignment - 1) / 3 {
        case 0: height - vertical
        case 1: height / 2
        default: vertical
        }
        return ASSPoint(x: x, y: y)
    }
}
