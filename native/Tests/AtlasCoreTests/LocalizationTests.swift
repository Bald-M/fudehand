import Foundation
import Testing
@testable import AtlasCore

private func temporaryDefaults() -> UserDefaults {
    UserDefaults(suiteName: "ui-atlas-tests-\(UUID().uuidString)")!
}

/// Format specifiers of a string, sorted, so tables can be compared regardless of argument order.
private func specifiers(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"%(\d+\$)?[@d]"#)
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }.sorted()
}

@Test func defaultsToUSEnglishUntilTheUserChooses() {
    let defaults = temporaryDefaults()
    #expect(AppLanguage.fallback == .enUS)
    #expect(AppLanguage.saved(in: defaults) == .enUS)
    defaults.set("fr-FR", forKey: AppLanguage.defaultsKey)
    #expect(AppLanguage.saved(in: defaults) == .enUS)
}

@Test func languageChoicePersists() {
    let defaults = temporaryDefaults()
    for language in AppLanguage.allCases {
        language.save(in: defaults)
        #expect(AppLanguage.saved(in: defaults) == language)
    }
}

@Test func appLanguagesPutTheChoiceFirstAndKeepTheSystemOrder() {
    #expect(AppLanguage.zhHant.preferredLanguages(system: ["ja-JP", "zh-Hant", "en-US"]) == ["zh-Hant", "ja-JP", "en-US"])
    #expect(AppLanguage.enUS.preferredLanguages(system: []) == ["en-US"])
}

// The Chinese in this file is deliberate: these tests assert the Chinese localization tables and language names.
@Test func supportsExactlyTheFourLanguages() {
    #expect(AppLanguage.allCases.map(\.rawValue) == ["en-US", "en-GB", "zh-Hans", "zh-Hant"])
    #expect(AppLanguage.allCases.map(\.displayName) == ["English (US)", "English (UK)", "简体中文", "繁體中文"])
}

@Test func everyLanguageHasTheSameKeys() {
    let reference = Set(L10n.table(.enUS).keys)
    #expect(!reference.isEmpty)
    for language in AppLanguage.allCases {
        let keys = Set(L10n.table(language).keys)
        #expect(keys.subtracting(reference).sorted() == [], "\(language.rawValue) has extra keys")
        #expect(reference.subtracting(keys).sorted() == [], "\(language.rawValue) is missing keys")
    }
}

@Test func translationsKeepFormatSpecifiersAndAreNotEmpty() {
    for language in AppLanguage.allCases {
        for (key, value) in L10n.table(language) {
            #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.rawValue): \(key)")
            // "%1$@" and "%@" both count as one object argument.
            let normalize = { (list: [String]) in list.map { String($0.suffix(1)) }.sorted() }
            #expect(normalize(specifiers(value)) == normalize(specifiers(key)), "\(language.rawValue): \(key)")
        }
    }
}

@Test func usEnglishIsTheSourceLanguage() {
    for (key, value) in L10n.table(.enUS) { #expect(value == key.components(separatedBy: "|")[0]) }
}

@Test func chineseTablesContainNoUntranslatedCopies() {
    // "API key" keeps the provider's own term in every language.
    let shared: Set<String> = ["API key"]
    for language in [AppLanguage.zhHans, .zhHant] {
        for (key, value) in L10n.table(language) where !shared.contains(key) {
            #expect(value != key, "\(language.rawValue): \(key)")
        }
    }
}

@Test func looksUpAndFormatsStrings() {
    #expect(L10n.string("Layers", language: .enUS) == "Layers")
    #expect(L10n.string("Layers", language: .zhHans) == "图层")
    #expect(L10n.string("Layers", language: .zhHant) == "圖層")
    #expect(L10n.string("%d layers selected", language: .zhHans, 3) == "已选 3 个图层")
    #expect(L10n.string("Could not read file: %@", language: .enGB, "a.uiatlas") == "Could not read file: a.uiatlas")
    #expect(L10n.string("no such key %@", language: .zhHans, "x") == "no such key x")
    #expect(L10n.string("Light|font weight", language: .enUS) == "Light")
    #expect(L10n.string("Light|font weight", language: .zhHans) == "细" && L10n.string("Light", language: .zhHans) == "浅色")
    #expect(L10n.string("Missing|context", language: .zhHant) == "Missing")
}

@Test func britishEnglishUsesBritishSpelling() {
    #expect(L10n.string("Center", language: .enUS) == "Center")
    #expect(L10n.string("Center", language: .enGB) == "Centre")
    #expect(L10n.string("Text color", language: .enGB) == "Text colour")
}

@Test func traditionalChineseIsNotSimplified() {
    #expect(L10n.string("Design", language: .zhHans) == "设计")
    #expect(L10n.string("Design", language: .zhHant) == "設計")
}

/// Every `L("…")` call in the sources must have an entry, otherwise the UI silently shows the key.
@Test func everyLocalizedCallHasATableEntry() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")
    let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
    let table = L10n.table(.enUS)
    var found = 0
    for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let literal = String(text[Range(match.range(at: 1), in: text)!])
            let key = literal.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n")
            found += 1
            #expect(table[key] != nil, "\(url.lastPathComponent): missing key \(key)")
        }
    }
    #expect(found > 100)
}

/// UI source files must not keep hard-coded Chinese copy outside comments.
/// Control-channel errors go to Agents and stay out of the string tables (issue #83).
@Test func uiSourcesHaveNoHardCodedChineseCopy() throws {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AtlasApp")
    let files = ["AtlasApp", "AtlasStore", "WorkspaceView", "LaunchView", "LayersPanel", "InspectorPanel", "ChatPanel", "ChatMessages", "ChatSession",
                 "Connectors", "Keychain", "CanvasView"]
    let literal = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    for name in files {
        let text = try String(contentsOf: app.appendingPathComponent("\(name).swift"), encoding: .utf8)
        for line in text.split(separator: "\n").map(String.init) {
            let code = line.components(separatedBy: "//")[0]
            if code.contains("ControlCommandError(") || code.contains("standardError") { continue }
            for match in literal.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let value = String(code[Range(match.range, in: code)!])
                #expect(!value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(name).swift: \(value)")
            }
        }
    }
}
