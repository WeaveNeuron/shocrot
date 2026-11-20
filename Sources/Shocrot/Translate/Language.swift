import Foundation
import NaturalLanguage

struct Language: Hashable, Identifiable {
    let code: String // BCP-47, e.g. "zh-Hans"
    /// In the UI language; a code we have no name for shows as itself.
    var name: String {
        let key = "language.\(code)"
        let name = L(key)
        return name == key ? code : name
    }
    var id: String { code }
    var locale: Locale.Language { Locale.Language(identifier: code) }
    var englishName: String { Locale(identifier: "en").localizedString(forIdentifier: code) ?? code }
    var isChinese: Bool { code.hasPrefix("zh") }

    /// Names live in Localizable.strings as `language.<code>`.
    static let all: [Language] = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it", "pt",
        "ru", "ar", "th", "vi", "id", "tr", "pl", "nl", "uk", "hi",
    ].map { Language(code: $0) }

    static func named(_ code: String) -> Language {
        all.first { $0.code == code } ?? Language(code: code)
    }

    /// Detects the dominant language of a snippet, restricted to the languages we offer.
    static func detect(_ text: String) -> Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = all.map { NLLanguage($0.code) }
        recognizer.processString(String(text.prefix(500)))
        return recognizer.dominantLanguage.map { named($0.rawValue) }
    }

    /// Text in the primary language goes to the secondary one; everything else goes to the primary.
    static func target(for source: Language) -> Language {
        let primary = named(Settings.shared.primaryLanguage)
        let isPrimary = source == primary || (source.isChinese && primary.isChinese)
        return isPrimary ? named(Settings.shared.secondaryLanguage) : primary
    }
}
