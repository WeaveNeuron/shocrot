import Foundation
import NaturalLanguage

struct Language: Hashable, Identifiable {
    let code: String // BCP-47, e.g. "zh-Hans"
    /// In the UI language; a code we have no name for shows as itself.
    var name: String { localizedName(in: L10n.language) }
    var id: String { code }
    var locale: Locale.Language { Locale.Language(identifier: code) }
    var englishName: String { Locale(identifier: "en").localizedString(forIdentifier: code) ?? code }
    var isChinese: Bool { code.hasPrefix("zh") }

    /// Display name localized to `language` (defaults to the current UI language).
    /// Prefers the app's curated string table for `language`, then falls back to Foundation's `Locale`
    /// for uncataloged or regional BCP-47 codes so non-English UIs never leak English names, then raw `code`.
    func localizedName(in language: String = L10n.language) -> String {
        let key = "language.\(code)"
        if let entry = L10n.table(language)[key] { return entry }
        if let localized = Locale(identifier: language).localizedString(forIdentifier: code), !localized.isEmpty {
            return localized
        }
        if let fallback = L10n.table(L10n.fallback)[key] { return fallback }
        return code
    }

    /// Names live in Localizable.strings as `language.<code>`.
    static let all: [Language] = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it", "pt",
        "ru", "ar", "th", "vi", "id", "tr", "pl", "nl", "uk", "hi",
    ].map { Language(code: $0) }

    static func named(_ code: String) -> Language {
        all.first { $0.code == code } ?? Language(code: code)
    }

    /// Detects the dominant language of a snippet, restricted to the languages we offer.
    ///
    /// A few Latin-script words carry little evidence, and the recognizer alone often picks a near neighbour of
    /// English ("Mac Studio Setup" came out Indonesian at 0.81, "Turbo" Portuguese at 0.26). Short Latin text,
    /// usually a title, label or menu item, is far more likely English than anything else, so it gets English as
    /// a prior (`shortLatinHints`) rather than a word list. Real short sentences in other Latin languages still win
    /// clearly: their own spelling outweighs the prior ("Merci beaucoup" stays French at 0.79, "Selamat pagi"
    /// Indonesian at 1.0). If even with the prior no language reaches `minimumConfidence`, short Latin text is
    /// taken as English: the likeliest case, and a wrong guess costs a visible, swappable translation, whereas
    /// "keep the previous language" would carry over a guess about unrelated text. Other scripts (CJK,
    /// Cyrillic, Arabic…) are told apart by the script itself and keep the recognizer's top answer.
    static func detect(_ text: String) -> Language? {
        let sample = String(text.prefix(500))
        let shortLatin = isShortLatin(sample)
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = all.map { NLLanguage($0.code) }
        if shortLatin { recognizer.languageHints = shortLatinHints }
        recognizer.processString(sample)
        let top = recognizer.languageHypotheses(withMaximum: 1).max { $0.value < $1.value }
        guard let top, top.value >= minimumConfidence || !shortLatin else {
            return shortLatin ? named("en") : nil
        }
        return named(top.key.rawValue)
    }

    /// The recognizer's answer for short Latin text is trusted from this probability up.
    static let minimumConfidence = 0.5
    /// Up to this many letters counts as short: a few words, like a title or a button.
    static let shortTextLetters = 40

    /// English 20 times as likely as each other language we offer, before the text is read.
    static var shortLatinHints: [NLLanguage: Double] {
        var hints = Dictionary(uniqueKeysWithValues: all.map { (NLLanguage($0.code), 0.02) })
        hints[.english] = 0.4
        return hints
    }

    /// Whether `text` has at least one letter, at most `shortTextLetters` of them, all in the Latin script
    /// (Basic Latin, Latin-1, Latin Extended A/B and Additional, which covers Vietnamese tone marks).
    static func isShortLatin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter(\.properties.isAlphabetic)
        guard !letters.isEmpty, letters.count <= shortTextLetters else { return false }
        return letters.allSatisfy { s in
            s.isASCII || (0x00C0...0x024F).contains(s.value) || (0x1E00...0x1EFF).contains(s.value)
        }
    }

    /// Text in the primary language goes to the secondary one; everything else goes to the primary.
    static func target(for source: Language) -> Language {
        let primary = named(Settings.shared.primaryLanguage)
        let isPrimary = source == primary || (source.isChinese && primary.isChinese)
        return isPrimary ? named(Settings.shared.secondaryLanguage) : primary
    }
}
