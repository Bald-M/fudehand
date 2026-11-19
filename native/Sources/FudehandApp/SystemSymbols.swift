import AppKit
import FudehandCore

/// SF Symbols as the `sf` icon library. They are not bundled: the system draws them by name. macOS has no public API that
/// lists the names, so search reads the list the system's glyph bundle ships; if that file moves, `sf` icons still draw and
/// validate by name but do not appear in search.
enum SystemSymbols {
    static let namesFile = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")

    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func names() -> [String] {
        guard let data = try? Data(contentsOf: namesFile),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let symbols = plist["symbols"] as? [String: Any] else { return [] }
        return Array(symbols.keys)
    }

    /// Gives the shared icon catalog access to SF Symbols.
    static func install() {
        IconCatalog.shared.symbolExists = { exists($0) }
        IconCatalog.shared.symbolNames = { names() }
    }
}
