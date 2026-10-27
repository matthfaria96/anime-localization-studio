import Foundation

/// Creating, renaming and removing styles, and the fonts a script needs. Lines that are not
/// touched keep their exact text.
extension ASSDocument {
    public var styleNames: [String] { styles.compactMap { $0["Name"] } }

    /// A free style name based on `base` (“Default 2”, “Default 3”…).
    public func uniqueStyleName(_ base: String) -> String {
        let taken = Set(styleNames.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Adds a copy of the style at `index` named `name`, right after it. Returns the new index.
    @discardableResult
    public mutating func duplicateStyle(at index: Int, named name: String) -> Int? {
        let indices = styleLineIndicesSnapshot
        guard indices.indices.contains(index), case .style(let original) = lines[indices[index]] else { return nil }
        var copy = original.detachedCopy()
        copy["Name"] = uniqueStyleName(name)
        insertLine(.style(copy), at: indices[index] + 1)
        return index + 1
    }

    /// Renames a style and every event that uses it.
    public mutating func renameStyle(at index: Int, to newName: String) {
        guard let old = styles[safe: index]?["Name"] else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        let unique = uniqueStyleName(name)
        updateStyle(at: index) { $0["Name"] = unique }
        for i in 0..<eventCount where event(at: i).styleName == old {
            updateEvent(at: i) { $0["Style"] = unique }
        }
    }

    /// Removes a style; the events that used it move to `replacement`.
    public mutating func removeStyle(at index: Int, movingEventsTo replacement: String) {
        let indices = styleLineIndicesSnapshot
        guard indices.indices.contains(index), case .style(let record) = lines[indices[index]], let old = record["Name"] else { return }
        for i in 0..<eventCount where event(at: i).styleName == old {
            updateEvent(at: i) { $0["Style"] = replacement }
        }
        removeLine(at: indices[index])
    }

    public func eventCount(usingStyle name: String) -> Int {
        events.filter { $0.styleName == name }.count
    }

    /// Font families the script asks for: each style's font and every inline `\fn` tag.
    public var usedFonts: [String] {
        var fonts = Set(styles.compactMap { $0["Fontname"]?.trimmingCharacters(in: .whitespaces) })
        let pattern = /\\fn([^\\}]+)/
        for event in events {
            for match in event.text.matches(of: pattern) {
                fonts.insert(String(match.1).trimmingCharacters(in: .whitespaces))
            }
        }
        return fonts.filter { !$0.isEmpty }.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
