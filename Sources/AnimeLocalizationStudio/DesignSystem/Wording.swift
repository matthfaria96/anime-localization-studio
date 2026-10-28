import Foundation
import StudioCore

/// Languages offered as output, with the name players show for the track.
enum Languages {
    static var all: [(code: String, name: String)] { InterfaceLanguage.outputs.map { ($0, name(for: $0)) } }

    static func name(for code: String) -> String { InterfaceLanguage.name(of: code) }

    /// `pt-BR` → `pt`, `ja-JP` → `ja`: to compare languages whatever the region.
    static func base(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code)).lowercased()
    }

    /// A track's language as people read it (“und” is “sem idioma”).
    static func display(_ code: String) -> String {
        code.isEmpty || code == "und" ? String(localized: "sem idioma") : code.uppercased()
    }
}

/// “1 fala”, “2 falas”: count agreement in one place (the words are translated).
enum Plural {
    static func count(_ n: Int, _ one: String.LocalizationValue, _ many: String.LocalizationValue) -> String {
        "\(n) \(String(localized: n == 1 ? one : many))"
    }
}
