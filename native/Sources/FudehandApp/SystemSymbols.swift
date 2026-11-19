import AppKit
import FudehandCore

/// SF Symbols as the `sf` icon library. They are not bundled: the system draws them by name. macOS has no public API that
/// lists the names, so search reads the list and the keywords the system's glyph bundle ships; if those files move, `sf`
/// icons still draw and validate by name but do not appear in search.
enum SystemSymbols {
    static let namesFile = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")

    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Search keywords the system offers per symbol name; like the name list, an undocumented file.
    static let tagsFile = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_search.plist")

    static func names() -> [String] {
        guard let data = try? Data(contentsOf: namesFile),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let symbols = plist["symbols"] as? [String: Any] else { return [] }
        return Array(symbols.keys)
    }

    static func tags() -> [String: [String]] {
        guard let data = try? Data(contentsOf: tagsFile),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return [:] }
        return plist.compactMapValues { $0 as? [String] }
    }

    /// Gives the shared icon catalog access to SF Symbols.
    static func install() {
        IconCatalog.shared.symbolExists = { exists($0) }
        IconCatalog.shared.symbolNames = { names() }
        IconCatalog.shared.symbolTags = { tags() }
    }
}
