import Foundation

/// The built-in icon libraries: which icon names exist, their artwork, search, and similar names for a mistyped one.
///
/// Bundled libraries are read lazily from `<library>.json.zlib`: the App carries them in `Contents/Resources/Icons`
/// (copied by `scripts/native-build.mjs`), and `swift test` reads them from the package's resource bundle (raw DEFLATE JSON written by
/// `scripts/build-icons.mjs`). SF Symbols come from the system, which only the App can reach, so the App sets
/// `symbolExists`, `symbolNames`, and `symbolTags` at launch.
public final class IconCatalog: @unchecked Sendable {
    public static let shared = IconCatalog()

    private struct Icon { let svg: String; let tags: [String] }

    private let lock = NSLock()
    private var libraries: [IconLibrary: [String: Icon]] = [:]
    private var symbolNameCache: [String]?
    private var symbolTagCache: [String: [String]]?
    private var _symbolExists: @Sendable (String) -> Bool
    private var _symbolNames: @Sendable () -> [String]
    private var _symbolTags: @Sendable () -> [String: [String]]

    public init(symbolExists: @escaping @Sendable (String) -> Bool = { _ in false },
                symbolNames: @escaping @Sendable () -> [String] = { [] },
                symbolTags: @escaping @Sendable () -> [String: [String]] = { [:] }) {
        _symbolExists = symbolExists
        _symbolNames = symbolNames
        _symbolTags = symbolTags
    }

    /// Whether the system has an SF Symbol with this name (without the `sf/` prefix).
    public var symbolExists: @Sendable (String) -> Bool {
        get { lock.withLock { _symbolExists } }
        set { lock.withLock { _symbolExists = newValue } }
    }

    /// All SF Symbol names the system offers, for search and suggestions; read once.
    public var symbolNames: @Sendable () -> [String] {
        get { lock.withLock { _symbolNames } }
        set { lock.withLock { _symbolNames = newValue; symbolNameCache = nil } }
    }

    /// Search keywords for SF Symbols by name (e.g. `magnifyingglass` → `search`); read once.
    public var symbolTags: @Sendable () -> [String: [String]] {
        get { lock.withLock { _symbolTags } }
        set { lock.withLock { _symbolTags = newValue; symbolTagCache = nil } }
    }

    /// The SVG source of a bundled icon; nil for SF Symbols and unknown names.
    public func svg(_ fullName: String) -> Data? {
        guard let (library, name) = IconLibrary.parse(fullName), library != .sf, let icon = icons(library)[name] else { return nil }
        return Data(icon.svg.utf8)
    }

    public func exists(_ fullName: String) -> Bool {
        guard let (library, name) = IconLibrary.parse(fullName) else { return false }
        return library == .sf ? symbolExists(name) : icons(library)[name] != nil
    }

    /// Up to `limit` names in the same library that look like `fullName`: names containing it (or contained in it) first,
    /// then by edit distance.
    public func suggestions(for fullName: String, limit: Int = 5) -> [String] {
        guard let (library, name) = IconLibrary.parse(fullName) else { return [] }
        let query = name.lowercased()
        let ranked = names(library).map { candidate -> (Int, Int, String) in
            let lower = candidate.lowercased()
            let related = lower.contains(query) || query.contains(lower)
            return (related ? 0 : 1, Self.editDistance(query, lower), candidate)
        }
        .sorted { ($0.0, $0.1, $0.2.count, $0.2) < ($1.0, $1.1, $1.2.count, $1.2) }
        return ranked.prefix(limit).map { "\(library.rawValue)/\($0.2)" }
    }

    /// Icons whose name or tags match `query`. Case and the word separators libraries use (space, `-`, `_`, `.`) are
    /// ignored, so `shopping cart` finds `shopping-cart`, `shopping_cart`, and `cart.shopping`-style names alike. Ranked:
    /// exact name, name prefix, name substring, every word in the name in any order, then every word in the name or tags;
    /// shorter names first within each rank.
    public func search(_ query: String, library: IconLibrary? = nil, limit: Int = 50) -> [String] {
        let query = Self.normalized(query)
        guard !query.isEmpty, limit > 0 else { return [] }
        let words = query.split(separator: " ")
        var hits: [(rank: Int, name: String)] = []
        for library in library.map({ [$0] }) ?? IconLibrary.allCases {
            let icons = library == .sf ? [:] : icons(library)
            let symbolTags = library == .sf ? self.symbolTagsCached() : [:]
            for name in names(library) {
                let normal = Self.normalized(name)
                let rank: Int
                if normal == query { rank = 0 }
                else if normal.hasPrefix(query) { rank = 1 }
                else if normal.contains(query) { rank = 2 }
                else if words.allSatisfy({ normal.contains($0) }) { rank = 3 }
                else {
                    let tags = (library == .sf ? symbolTags[name] : icons[name]?.tags) ?? []
                    guard !tags.isEmpty else { continue }
                    let text = normal + " " + tags.map(Self.normalized).joined(separator: " ")
                    guard words.allSatisfy({ text.contains($0) }) else { continue }
                    rank = 4
                }
                hits.append((rank, "\(library.rawValue)/\(name)"))
            }
        }
        hits.sort { ($0.rank, $0.name.count, $0.name) < ($1.rank, $1.name.count, $1.name) }
        return hits.prefix(limit).map(\.name)
    }

    /// Lowercased, with `-`, `_`, `.`, and runs of whitespace turned into single spaces.
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Loading

    private func symbolTagsCached() -> [String: [String]] {
        if let cached = lock.withLock({ symbolTagCache }) { return cached }
        let tags = symbolTags()
        lock.withLock { symbolTagCache = tags }
        return tags
    }

    private func names(_ library: IconLibrary) -> [String] {
        guard library == .sf else { return Array(icons(library).keys) }
        if let cached = lock.withLock({ symbolNameCache }) { return cached }
        let names = symbolNames()
        lock.withLock { symbolNameCache = names }
        return names
    }

    private func icons(_ library: IconLibrary) -> [String: Icon] {
        lock.withLock {
            if let loaded = libraries[library] { return loaded }
            let loaded = library == .sf ? [:] : load(library)
            libraries[library] = loaded
            return loaded
        }
    }

    private func load(_ library: IconLibrary) -> [String: Icon] {
        guard let url = Self.resource(library.rawValue),
              let compressed = try? Data(contentsOf: url),
              let json = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let icons = object["icons"] as? [String: [String: Any]] else { return [:] }
        return icons.compactMapValues { value in
            (value["svg"] as? String).map { Icon(svg: $0, tags: value["tags"] as? [String] ?? []) }
        }
    }

    static func resource(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "json.zlib", subdirectory: "Icons") { return url }
        // The app bundle does not carry the package's resource bundle, and asking for a missing one traps.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: name, withExtension: "json.zlib")
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        if a.isEmpty { return b.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
