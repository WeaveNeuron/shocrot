import Foundation
import NaturalLanguage

struct Language: Hashable, Identifiable {
    let code: String // BCP-47, e.g. "zh-Hans"
    let name: String
    var id: String { code }
    var locale: Locale.Language { Locale.Language(identifier: code) }
    var englishName: String { Locale(identifier: "en").localizedString(forIdentifier: code) ?? code }
    var isChinese: Bool { code.hasPrefix("zh") }

    static let all: [Language] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"), ("it", "意大利语"), ("pt", "葡萄牙语"),
        ("ru", "俄语"), ("ar", "阿拉伯语"), ("th", "泰语"), ("vi", "越南语"), ("id", "印尼语"),
        ("tr", "土耳其语"), ("pl", "波兰语"), ("nl", "荷兰语"), ("uk", "乌克兰语"), ("hi", "印地语"),
    ].map { Language(code: $0.0, name: $0.1) }

    static func named(_ code: String) -> Language {
        all.first { $0.code == code } ?? Language(code: code, name: code)
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
