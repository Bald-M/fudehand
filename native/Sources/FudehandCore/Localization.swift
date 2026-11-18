import Foundation

/// The UI languages the App offers. Raw values are BCP 47 tags and are what gets saved.
public enum AppLanguage: String, CaseIterable, Sendable {
    case enUS = "en-US"
    case enGB = "en-GB"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"

    /// Used until the user picks a language; the App does not follow the system language.
    public static let fallback = AppLanguage.enUS
    public static let defaultsKey = "app.language"

    /// The language's own name, shown untranslated in the language menu.
    public var displayName: String {
        switch self {
        case .enUS: return "English (US)"
        case .enGB: return "English (UK)"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }

    /// Name of the `.lproj` folder holding this language's table; US English is the source language.
    var resourceName: String { self == .enUS ? "en" : rawValue }

    public var locale: Locale { Locale(identifier: rawValue) }

    public static func saved(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? fallback
    }

    public func save(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// The app's `AppleLanguages` value: this language first, so system-provided menu items use it at the next
    /// launch, then the user's system languages, so font fallback for text on the canvas stays as the system has it.
    public func preferredLanguages(system: [String]) -> [String] {
        [rawValue] + system.filter { $0 != rawValue }
    }

    /// The system-wide preferred languages, read past any per-app override.
    public static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []
    }
}

/// String tables for the UI. Keys are the US English text.
public enum L10n {
    private static let lock = NSLock()
    private static var current = AppLanguage.fallback
    private static var tables: [AppLanguage: [String: String]] = [:]

    /// The language `L(_:)` uses. The App sets it at launch and whenever the user switches.
    public static var language: AppLanguage {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public static func table(_ language: AppLanguage) -> [String: String] {
        lock.withLock {
            if let table = tables[language] { return table }
            let table = url(language).flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
            tables[language] = table
            return table
        }
    }

    /// The app bundle carries the tables in `Contents/Resources`; `swift test` reads them from the package's resource bundle.
    private static func url(_ language: AppLanguage) -> URL? {
        if let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.resourceName) {
            return url
        }
        // The app bundle does not carry the package's resource bundle, and asking for a missing one traps.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.resourceName)
    }

    /// A missing key falls back to the key itself, which is readable US English. Text after "|" in a key only
    /// tells apart identical English words ("Light|font weight") and is never shown.
    public static func string(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        string(key, language: language, arguments: arguments)
    }

    static func string(_ key: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        let template = table(language)[key] ?? key.components(separatedBy: "|")[0]
        return arguments.isEmpty ? template : String(format: template, arguments: arguments)
    }
}

/// The UI string for `key` in the current language, with `String(format:)` arguments.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.string(key, language: L10n.language, arguments: arguments)
}
