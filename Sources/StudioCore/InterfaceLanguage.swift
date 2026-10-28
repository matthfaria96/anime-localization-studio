import Foundation

/// The language the app speaks (Brazilian Portuguese or English), for the names it writes
/// itself, such as a new track's “Japonês” / “Japanese”.
public enum InterfaceLanguage {
    /// Languages offered as output, in the order the pickers show them.
    public static let outputs = ["pt-BR", "pt-PT", "es", "en", "fr", "de", "it", "ja", "ko", "zh"]

    /// `pt-BR` or `en`. Outside the app (tests, tools) the texts stay in the source language.
    public static var identifier: String {
        guard Bundle.main.localizations.contains("en") else { return "pt-BR" }
        return Bundle.main.preferredLocalizations.first ?? "pt-BR"
    }

    /// “Japonês”, “Português (Brasil)”: a language as the interface names it, capitalized.
    public static func name(of code: String) -> String {
        let locale = Locale(identifier: identifier)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The output people most likely want: their system language when it is offered, else English.
    public static var defaultOutput: String {
        for preferred in Locale.preferredLanguages {
            let base = String(preferred.split(separator: "-").first ?? "").lowercased()
            if base == "pt" { return preferred.hasPrefix("pt-PT") ? "pt-PT" : "pt-BR" }
            if outputs.contains(base) { return base }
        }
        return "en"
    }
}
