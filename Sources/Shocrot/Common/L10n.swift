import Foundation

/// The UI language chosen in Settings › General. Stored under `appLanguage`; a missing or unknown value means
/// "follow the system", which is also what every install that predates this setting gets.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    static let defaultsKey = "appLanguage"

    /// Each language is named in itself, so it can be found whatever the current UI language is.
    var title: String {
        switch self {
        case .system: L("settings.language.system")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static func stored(in defaults: UserDefaults) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// Saves the choice. An explicit language is also written to this app's `AppleLanguages`, so the parts macOS
    /// draws itself (open/save panels, alert buttons, the Info.plist strings) follow it from the next launch.
    /// "Follow the system" removes that override again. Only the app's own defaults domain is touched.
    static func store(_ language: AppLanguage, in defaults: UserDefaults) {
        defaults.set(language.rawValue, forKey: defaultsKey)
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Looks up user-facing text in `<lang>.lproj/Localizable.strings`. English is the development language and the
/// fallback for anything missing. The language is picked once per launch, so the whole UI stays in one language;
/// a change in Settings applies after a restart.
enum L10n {
    /// Localizations shipped with the app, development language first.
    static let supported = ["en", "zh-Hans"]
    static let fallback = "en"

    /// The Settings choice this launch started with.
    static let launchChoice = AppLanguage.stored(in: .standard)

    /// The language the UI uses for this launch.
    static let language: String = resolve(launchChoice, preferred: Locale.preferredLanguages)

    /// For formatting numbers and dates so they match the UI language.
    static var locale: Locale { Locale(identifier: language) }

    /// An explicit choice wins; otherwise the user's first preferred language that we ship, else English.
    static func resolve(_ choice: AppLanguage, preferred: [String]) -> String {
        if choice != .system { return choice.rawValue }
        for code in preferred {
            if let match = supportedLocalization(for: code) { return match }
        }
        return fallback
    }

    /// "en-GB" → "en", "zh-Hans-CN" or the legacy "zh-CN" → "zh-Hans"; Traditional Chinese and anything else → nil.
    static func supportedLocalization(for code: String) -> String? {
        let language = Locale.Language(identifier: code)
        switch language.languageCode?.identifier {
        case "en": return "en"
        case "zh":
            let script = language.script?.identifier
            if script == "Hans" { return "zh-Hans" }
            if script == "Hant" { return nil }
            // No script given: mainland China and Singapore write Simplified.
            let region = language.region?.identifier
            return region == nil || region == "CN" || region == "SG" ? "zh-Hans" : nil
        default: return nil
        }
    }

    /// `key` in the given language, then in English, then the key itself (so a gap shows up instead of a blank).
    static func string(_ key: String, language: String) -> String {
        table(language)[key] ?? table(fallback)[key] ?? key
    }

    /// Count-dependent text: `key.one` when `count` is 1 and the language has that form, `key.other` otherwise.
    static func plural(_ key: String, _ count: Int, language: String = language) -> String {
        let format = (count == 1 ? table(language)["\(key).one"] : nil) ?? string("\(key).other", language: language)
        return String(format: format, locale: Locale(identifier: language), count)
    }

    // MARK: Tables

    private static let tables: [String: [String: String]] = Dictionary(uniqueKeysWithValues: supported.map {
        ($0, loadTable("Localizable", language: $0))
    })

    static func table(_ language: String) -> [String: String] { tables[language] ?? [:] }

    /// Reads `<language>.lproj/<name>.strings` from the resource bundle. SwiftPM lowercases the folder name
    /// ("zh-hans.lproj"), the app bundle keeps the canonical one, so both spellings are tried.
    static func loadTable(_ name: String, language: String, in bundle: Bundle? = resourceBundle) -> [String: String] {
        guard let bundle else { return [:] }
        for localization in [language, language.lowercased()] {
            if let url = bundle.url(forResource: name, withExtension: "strings", subdirectory: nil, localization: localization),
               let table = NSDictionary(contentsOf: url) as? [String: String] {
                return table
            }
        }
        return [:]
    }

    /// Where the `.lproj` folders are. The packaged app carries them in Contents/Resources. `swift run` and
    /// `swift test` find them in SwiftPM's resource bundle next to the executable or test bundle. (SwiftPM's
    /// generated `Bundle.module` would also work, but it embeds the build machine's absolute path in the binary.)
    static let resourceBundle: Bundle? = {
        if Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                           localization: fallback) != nil {
            return .main
        }
        let name = "Shocrot_Shocrot.bundle"
        let places = [Bundle.main.bundleURL, Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                      Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()]
        for case let dir? in places {
            if let bundle = Bundle(url: dir.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()

    private final class BundleToken {}
}

/// Localized text for `key` in the UI language.
func L(_ key: String) -> String {
    L10n.string(key, language: L10n.language)
}

/// Localized format string for `key`, filled in with `args` (use positional `%1$@` when languages reorder them).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: L10n.locale, arguments: args)
}
