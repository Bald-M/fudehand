import Foundation

/// 侧栏作品的排序方式。
public enum ProjectOrder: String, CaseIterable, Sendable {
    /// catalog.json 中的顺序。
    case catalog
    /// 作品目录最近修改的在前。
    case recent
}

public enum SidebarOrdering {
    /// 置顶作品在前；两组内部各按 `order` 稳定排序，修改时间未知的排在“最近修改”末尾。
    public static func order(_ projects: [Project], by order: ProjectOrder, pinned: Set<String>,
                             modified: [String: Date]) -> [Project] {
        let indexed = Array(projects.enumerated())
        func before(_ a: (offset: Int, element: Project), _ b: (offset: Int, element: Project)) -> Bool {
            let aPinned = pinned.contains(a.element.id), bPinned = pinned.contains(b.element.id)
            if aPinned != bPinned { return aPinned }
            if order == .recent {
                switch (modified[a.element.id], modified[b.element.id]) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return a.offset < b.offset
        }
        return indexed.sorted(by: before).map(\.element)
    }

    /// 生成物和依赖目录不代表作者的修改。
    private static let ignored: Set<String> = ["node_modules", "dist", "build"]

    /// 目录下普通文件的最新修改时间，跳过隐藏条目与依赖、构建目录；目录不存在或没有文件时为 nil。
    public static func lastModified(directory: URL) -> Date? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var latest: Date?
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if ignored.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true, let date = values.contentModificationDate, latest.map({ date > $0 }) ?? true {
                latest = date
            }
        }
        return latest
    }
}
