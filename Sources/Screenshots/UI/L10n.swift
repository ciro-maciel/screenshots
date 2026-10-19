import Foundation

/// The interface language. The app follows the Mac: Brazilian Portuguese when the first
/// preferred language is Portuguese, English for anything else. There is no switch inside the app.
///
/// Keys are the English text, so a key missing from a table still shows English, never a key
/// name. Where one English text needs two Portuguese ones, the key carries a context before a
/// bar ("settings|Thin"); without a table entry the text after the bar shows. The tables live in
/// Resources/en.lproj and Resources/pt-BR.lproj (Localizable.strings).
enum L10n {
    static let isPortuguese: Bool = (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("pt")

    /// The chosen table, read directly: Bundle's own matching would pick pt-BR for a person whose
    /// list is, say, French then Portuguese, and the rule says English there.
    private static let table: Bundle? = bundle(isPortuguese ? "pt-BR" : "en")
    private static let english: Bundle? = bundle("en")

    private static func bundle(_ lang: String) -> Bundle? {
        Bundle.main.path(forResource: lang, ofType: "lproj").flatMap { Bundle(path: $0) }
    }

    /// For dates and numbers shown in the interface: the Mac's own locale when it speaks the
    /// interface language (keeps the region's conventions), otherwise a plain one in that language.
    static let locale: Locale = {
        let current = Locale.current
        let want = isPortuguese ? "pt" : "en"
        if current.language.languageCode?.identifier == want { return current }
        return Locale(identifier: isPortuguese ? "pt_BR" : "en_US")
    }()

    static func string(_ key: String) -> String {
        let missing = "\u{0}missing"
        if let t = table?.localizedString(forKey: key, value: missing, table: nil), t != missing { return t }
        if let t = english?.localizedString(forKey: key, value: missing, table: nil), t != missing { return t }
        return key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
    }
}

/// The interface text for an English key, in the Mac's language.
func L(_ key: String) -> String { L10n.string(key) }

/// The same, with `%@`/`%d` arguments filled in.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key), locale: L10n.locale, arguments: args)
}
