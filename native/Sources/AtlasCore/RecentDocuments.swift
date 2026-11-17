import Foundation

/// 一条最近打开记录：工程文件的绝对路径与最近一次打开或保存的时间。
public struct RecentDocument: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let openedAt: Date

    public init(path: String, openedAt: Date) {
        self.path = path
        self.openedAt = openedAt
    }
}

/// 最近打开的工程文件：按时间倒序、按路径去重，最多保留 `limit` 条。启动窗口与“打开最近”菜单共用。
public struct RecentDocuments: Equatable, Sendable {
    public static let limit = 10

    /// 列表中的一项；`available` 为假表示文件已被删除或移动。
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let openedAt: Date
        public let available: Bool
    }

    public private(set) var items: [RecentDocument] = []

    public init() {}

    /// 读取持久化的记录；数据缺失或损坏时为空，重复和超出上限的部分去掉。
    public init(data: Data?) {
        guard let data, let stored = try? JSONDecoder().decode([RecentDocument].self, from: data) else { return }
        for item in stored.sorted(by: { $0.openedAt > $1.openedAt }) where !items.contains(where: { $0.path == item.path }) {
            items.append(item)
        }
        items = Array(items.prefix(Self.limit))
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(items)) ?? Data("[]".utf8) }

    /// 记录一次打开或保存：已有的同一路径移到最前。
    public mutating func record(_ path: String, at date: Date) {
        items.removeAll { $0.path == path }
        items.insert(RecentDocument(path: path, openedAt: date), at: 0)
        items = Array(items.prefix(Self.limit))
    }

    public mutating func remove(_ path: String) { items.removeAll { $0.path == path } }

    public mutating func clear() { items.removeAll() }

    /// 用于显示的列表，标出已不存在的文件。
    public func entries(exists: (String) -> Bool) -> [Entry] {
        items.map { Entry(path: $0.path, openedAt: $0.openedAt, available: exists($0.path)) }
    }
}
