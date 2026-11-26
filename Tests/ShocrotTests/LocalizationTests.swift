import Foundation
import Testing
@testable import Shocrot

/// Sources/Shocrot, found from this file so the tests don't depend on the working directory.
private let sourcesDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Shocrot")

private func table(_ language: String, _ name: String = "Localizable") -> [String: String] {
    L10n.loadTable(name, language: language)
}

/// Format specifiers by kind, ignoring positions (`%1$@` and `%@` are both "@"); `%%` is not an argument.
private func specifiers(_ s: String) -> [String] {
    let regex = #/%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?([@dDuUxXoOfeEgGcCsSp%])/#
    return s.matches(of: regex).map { String($0.output.1) }.filter { $0 != "%" }.sorted()
}

/// Every key the app's code asks for: `L("…")`, `L10n.plural("…")` (as `….other`/`….one`), `L10n.string("…")`.
private func keysUsedInSources() throws -> (plain: Set<String>, plural: Set<String>) {
    var plain = Set<String>(), plural = Set<String>()
    let files = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)!
    for case let url as URL in files where url.pathExtension == "swift" {
        let code = try String(contentsOf: url, encoding: .utf8)
        for m in code.matches(of: #/(?:^|[^\w.])L\("([^"\\]+)"/#) { plain.insert(String(m.output.1)) }
        for m in code.matches(of: #/L10n\.string\("([^"\\]+)"/#) { plain.insert(String(m.output.1)) }
        for m in code.matches(of: #/L10n\.plural\("([^"\\]+)"/#) { plural.insert(String(m.output.1)) }
    }
    return (plain, plural)
}

@Suite("Localization tables")
struct LocalizationTableTests {
    @Test func bothLanguagesShipTheirTables() {
        #expect(L10n.resourceBundle != nil)
        for language in L10n.supported {
            #expect(table(language).count > 200, "Localizable.strings missing for \(language)")
            #expect(table(language, "InfoPlist")["NSScreenCaptureUsageDescription"]?.isEmpty == false)
        }
        #expect(table("en")["menu.quit"] == "Quit Shocrot")
        #expect(table("zh-Hans")["menu.quit"] == "退出 Shocrot")
    }

    /// Chinese has no singular form, so it may leave out `.one`; otherwise both tables have the same keys.
    @Test func chineseCoversEveryEnglishKey() {
        let en = Set(table("en").keys), zh = Set(table("zh-Hans").keys)
        #expect(en.filter { !$0.hasSuffix(".one") }.subtracting(zh).sorted() == [])
        #expect(zh.subtracting(en).sorted() == [])
        #expect(Set(table("en", "InfoPlist").keys) == Set(table("zh-Hans", "InfoPlist").keys))
    }

    @Test func translationsKeepTheFormatSpecifiers() {
        let en = table("en"), zh = table("zh-Hans")
        for (key, english) in en where !key.hasSuffix(".one") {
            guard let chinese = zh[key] else { continue }
            #expect(specifiers(english) == specifiers(chinese), "\(key): \(english) / \(chinese)")
        }
    }

    @Test func everyKeyTheCodeUsesExists() throws {
        let (plain, plural) = try keysUsedInSources()
        #expect(plain.count > 150) // the scan itself works
        let en = table("en"), zh = table("zh-Hans")
        #expect(plain.filter { en[$0] == nil }.sorted() == [])
        #expect(plain.filter { zh[$0] == nil }.sorted() == [])
        for key in plural {
            #expect(en["\(key).one"] != nil && en["\(key).other"] != nil, "\(key)")
            #expect(zh["\(key).other"] != nil, "\(key)")
        }
    }

    /// Keeps the tables free of leftovers. Language names are looked up as `language.<code>`.
    @Test func everyEnglishKeyIsUsed() throws {
        let (plain, plural) = try keysUsedInSources()
        let used = plain.union(plural.flatMap { ["\($0).one", "\($0).other"] })
            .union(Language.all.map { "language.\($0.code)" })
        #expect(Set(table("en").keys).subtracting(used).sorted() == [])
    }
}

@Suite("Localization lookup")
struct LocalizationLookupTests {
    @Test func looksUpTheRequestedLanguage() {
        #expect(L10n.string("common.cancel", language: "en") == "Cancel")
        #expect(L10n.string("common.cancel", language: "zh-Hans") == "取消")
    }

    @Test func fallsBackToEnglishThenToTheKey() {
        #expect(L10n.string("common.cancel", language: "fr") == "Cancel")
        #expect(L10n.string("no.such.key", language: "zh-Hans") == "no.such.key")
        #expect(L10n.string("no.such.key", language: "en") == "no.such.key")
    }

    @Test func pluralsPickTheRightForm() {
        #expect(L10n.plural("ocr.lines", 1, language: "en") == "1 line")
        #expect(L10n.plural("ocr.lines", 2, language: "en") == "2 lines")
        #expect(L10n.plural("ocr.lines", 0, language: "en") == "0 lines")
        // No `.one` in Chinese: the English singular must not leak in.
        #expect(L10n.plural("ocr.lines", 1, language: "zh-Hans") == "1 行")
        #expect(L10n.plural("history.count", 3, language: "zh-Hans") == "3 项")
    }

    @Test func positionalArgumentsFillIn() {
        let zh = L10n.string("error.httpStatus", language: "zh-Hans")
        #expect(String(format: zh, 404, "Not Found") == "接口返回 404：Not Found")
        let en = L10n.string("toast.shortcutInUse", language: "en")
        #expect(String(format: en, "⌥⇧A", "Capture Area") == "⌥⇧A is already used for “Capture Area”")
        #expect(String(format: L10n.string("pin.opacityLabel", language: "en"), 80) == "80% opacity")
    }

    @Test func theCurrentLanguageIsOneWeShip() {
        #expect(L10n.supported.contains(L10n.language))
        #expect(L("common.cancel") == L10n.string("common.cancel", language: L10n.language))
    }
}

@Suite("App language")
struct AppLanguageTests {
    @Test func followingTheSystemPicksTheFirstLanguageWeShip() {
        #expect(L10n.resolve(.system, preferred: ["en-US"]) == "en")
        #expect(L10n.resolve(.system, preferred: ["en-GB", "zh-Hans-CN"]) == "en")
        #expect(L10n.resolve(.system, preferred: ["zh-Hans-US", "en-US"]) == "zh-Hans")
        #expect(L10n.resolve(.system, preferred: ["zh-CN"]) == "zh-Hans")
        #expect(L10n.resolve(.system, preferred: ["fr-FR", "zh-Hans"]) == "zh-Hans")
    }

    @Test func anythingElseFallsBackToEnglish() {
        #expect(L10n.resolve(.system, preferred: []) == "en")
        #expect(L10n.resolve(.system, preferred: ["fr-FR", "de-DE"]) == "en")
        #expect(L10n.resolve(.system, preferred: ["zh-Hant-TW"]) == "en")
        #expect(L10n.resolve(.system, preferred: ["zh-TW"]) == "en")
        #expect(L10n.resolve(.system, preferred: ["zh-HK"]) == "en")
    }

    @Test func anExplicitChoiceWins() {
        #expect(L10n.resolve(.english, preferred: ["zh-Hans-CN"]) == "en")
        #expect(L10n.resolve(.simplifiedChinese, preferred: ["en-US"]) == "zh-Hans")
    }

    @Test func storingTheChoiceAlsoSetsTheAppsAppleLanguages() throws {
        let suite = "com.weaveneuron.shocrot.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Installs from before this setting existed follow the system and keep their AppleLanguages untouched.
        #expect(AppLanguage.stored(in: defaults) == .system)
        defaults.set("klingon", forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.stored(in: defaults) == .system)

        AppLanguage.store(.simplifiedChinese, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .simplifiedChinese)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["zh-Hans"])

        AppLanguage.store(.english, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .english)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["en"])

        AppLanguage.store(.system, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .system)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    }

    @Test func languagesAreNamedInThemselves() {
        #expect(AppLanguage.english.title == "English")
        #expect(AppLanguage.simplifiedChinese.title == "简体中文")
        #expect(AppLanguage.system.title == L("settings.language.system"))
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "en", "zh-Hans"])
    }
}

@Suite("Localized language names")
struct LocalizedLanguageNameTests {
    @Test func followsChineseInterfaceForAllSupportedLanguages() {
        #expect(Language.named("zh-Hans").localizedName(in: "zh-Hans") == "简体中文")
        #expect(Language.named("en").localizedName(in: "zh-Hans") == "英语")
        #expect(Language.named("ja").localizedName(in: "zh-Hans") == "日语")
        #expect(Language.named("fr").localizedName(in: "zh-Hans") == "法语")
        for lang in Language.all {
            let zh = lang.localizedName(in: "zh-Hans")
            let en = lang.localizedName(in: "en")
            #expect(!zh.isEmpty && zh != lang.code, "\(lang.code) missing zh-Hans localization")
            #expect(zh != en, "\(lang.code) leaked English name '\(en)' into zh-Hans UI")
        }
    }

    @Test func keepsEnglishNamesInEnglishInterfaceAndLLMPrompts() {
        #expect(Language.named("zh-Hans").localizedName(in: "en") == "Chinese (Simplified)")
        #expect(Language.named("zh-Hant").localizedName(in: "en") == "Chinese (Traditional)")
        #expect(Language.named("en").localizedName(in: "en") == "English")
        #expect(Language.named("ja").localizedName(in: "en") == "Japanese")
        #expect(Language.named("zh-Hans").englishName.contains("Chinese"))
        #expect(Language.named("en").englishName == "English")
    }

    @Test func uncatalogedAndRegionalCodesLocalizeIntoUILanguage() {
        // Codes outside Localizable.strings fall back to Locale(identifier: uiLanguage), never leaking English to zh-Hans.
        let svZh = Language.named("sv").localizedName(in: "zh-Hans")
        let svEn = Language.named("sv").localizedName(in: "en")
        #expect(svZh != "sv" && svZh != svEn)
        #expect(svEn == "Swedish")

        let regionalZh = Language.named("zh-Hans-CN").localizedName(in: "zh-Hans")
        #expect(regionalZh.contains("中文"))
        // Unknown invalid codes still fall back to the raw identifier.
        #expect(Language.named("xx").localizedName(in: "zh-Hans") == "xx")
        #expect(Language.named("xx").localizedName(in: "en") == "xx")
    }

    @Test func nameMatchesCurrentUILanguage() {
        for lang in [Language.named("zh-Hans"), Language.named("en"), Language.named("ja")] {
            #expect(lang.name == lang.localizedName(in: L10n.language))
        }
    }
}
