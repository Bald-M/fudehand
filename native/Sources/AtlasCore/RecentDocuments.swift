import Foundation

/// One Open Recent entry: the absolute path of a project file and the time it was last opened or saved.
public struct RecentDocument: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let openedAt: Date

    public init(path: String, openedAt: Date) {
        self.path = path
        self.openedAt = openedAt
    }
}

/// The recently opened project files: newest first, deduplicated by path, keeping at most `limit` entries. Shared by the launch window and the "Open Recent" menu.
public struct RecentDocuments: Equatable, Sendable {
    public static let limit = 10

    /// One item in the list; `available` being false means the file was deleted or moved.
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let openedAt: Date
        public let available: Bool
    }

    public private(set) var items: [RecentDocument] = []

    public init() {}

    /// Reads the persisted entries; empty when the data is missing or corrupted, with duplicates and anything beyond the limit dropped.
    public init(data: Data?) {
        guard let data, let stored = try? JSONDecoder().decode([RecentDocument].self, from: data) else { return }
        for item in stored.sorted(by: { $0.openedAt > $1.openedAt }) where !items.contains(where: { $0.path == item.path }) {
            items.append(item)
        }
        items = Array(items.prefix(Self.limit))
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(items)) ?? Data("[]".utf8) }

    /// Records one open or save: an existing entry with the same path moves to the front.
    public mutating func record(_ path: String, at date: Date) {
        items.removeAll { $0.path == path }
        items.insert(RecentDocument(path: path, openedAt: date), at: 0)
        items = Array(items.prefix(Self.limit))
    }

    public mutating func remove(_ path: String) { items.removeAll { $0.path == path } }

    public mutating func clear() { items.removeAll() }

    /// The list for display, marking the files that no longer exist.
    public func entries(exists: (String) -> Bool) -> [Entry] {
        items.map { Entry(path: $0.path, openedAt: $0.openedAt, available: exists($0.path)) }
    }
}
