import Foundation

/// Languages offered as output, with the name players show for the track.
enum Languages {
    static let all: [(code: String, name: String)] = [
        ("pt-BR", "Português (Brasil)"), ("pt-PT", "Português (Portugal)"), ("es", "Espanhol"), ("en", "Inglês"),
        ("fr", "Francês"), ("de", "Alemão"), ("it", "Italiano"), ("ja", "Japonês"), ("ko", "Coreano"), ("zh", "Chinês")
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// `pt-BR` → `pt`, `ja-JP` → `ja`: to compare languages whatever the region.
    static func base(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code)).lowercased()
    }

    /// A track's language as people read it (“und” is “sem idioma”).
    static func display(_ code: String) -> String {
        code.isEmpty || code == "und" ? "sem idioma" : code.uppercased()
    }
}

/// “1 fala”, “2 falas”: Portuguese count agreement in one place.
enum Plural {
    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}
