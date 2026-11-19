import Foundation

/// The built-in icon libraries: which icon names exist, their artwork, search, and similar names for a mistyped one.
///
/// Bundled libraries are read lazily from `Resources/Icons/<library>.json.zlib` (flattened into the resource bundle) (raw DEFLATE JSON written by
/// `scripts/build-icons.mjs`). SF Symbols come from the system, which only the App can reach, so the App sets
/// `symbolExists` and `symbolNames` at launch.
public final class IconCatalog: @unchecked Sendable {
    public static let shared = IconCatalog()

    private struct Icon { let svg: String; let tags: [String] }

    private let bundle: Bundle
    private let lock = NSLock()
    private var libraries: [IconLibrary: [String: Icon]] = [:]
    private var symbolNameCache: [String]?
    private var _symbolExists: @Sendable (String) -> Bool
    private var _symbolNames: @Sendable () -> [String]

    public convenience init(symbolExists: @escaping @Sendable (String) -> Bool = { _ in false },
                            symbolNames: @escaping @Sendable () -> [String] = { [] }) {
        self.init(bundle: .module, symbolExists: symbolExists, symbolNames: symbolNames)
    }

    public init(bundle: Bundle, symbolExists: @escaping @Sendable (String) -> Bool = { _ in false },
                symbolNames: @escaping @Sendable () -> [String] = { [] }) {
        self.bundle = bundle
        _symbolExists = symbolExists
        _symbolNames = symbolNames
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

    /// Icons whose name or tags match `query` (case-insensitive): exact name, then name prefix, then name substring,
    /// then tag; shorter names first within each rank.
    public func search(_ query: String, library: IconLibrary? = nil, limit: Int = 50) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, limit > 0 else { return [] }
        var hits: [(rank: Int, name: String)] = []
        for library in library.map({ [$0] }) ?? IconLibrary.allCases {
            let icons = library == .sf ? [:] : icons(library)
            for name in names(library) {
                let lower = name.lowercased()
                let rank: Int
                if lower == query { rank = 0 }
                else if lower.hasPrefix(query) { rank = 1 }
                else if lower.contains(query) { rank = 2 }
                else if icons[name]?.tags.contains(where: { $0.lowercased().contains(query) }) == true { rank = 3 }
                else { continue }
                hits.append((rank, "\(library.rawValue)/\(name)"))
            }
        }
        hits.sort { ($0.rank, $0.name.count, $0.name) < ($1.rank, $1.name.count, $1.name) }
        return hits.prefix(limit).map(\.name)
    }

    // MARK: Loading

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
        guard let url = bundle.url(forResource: library.rawValue, withExtension: "json.zlib"),
              let compressed = try? Data(contentsOf: url),
              let json = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let icons = object["icons"] as? [String: [String: Any]] else { return [:] }
        return icons.compactMapValues { value in
            (value["svg"] as? String).map { Icon(svg: $0, tags: value["tags"] as? [String] ?? []) }
        }
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
