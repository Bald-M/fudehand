import Foundation
import Testing
import AtlasCore

private func projects(_ ids: [String]) throws -> [Project] {
    let base = try sampleCatalog().projects[0]
    return ids.map { id in var project = base; project.id = id; return project }
}

private func date(_ year: Int) -> Date {
    DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: year, month: 1, day: 1).date!
}

@Test func catalogOrderKeepsCatalogWithPinnedFirst() throws {
    let ordered = SidebarOrdering.order(try projects(["a", "b", "c", "d"]), by: .catalog, pinned: ["c", "d"], modified: [:])
    #expect(ordered.map(\.id) == ["c", "d", "a", "b"])
}

@Test func recentOrderSortsDescendingUnknownLast() throws {
    let modified = ["a": date(2020), "b": date(2024), "d": date(2022)]
    let ordered = SidebarOrdering.order(try projects(["a", "b", "c", "d", "e"]), by: .recent, pinned: ["a"], modified: modified)
    #expect(ordered.map(\.id) == ["a", "b", "d", "c", "e"])
}

@Test func stalePinnedIdsIgnored() throws {
    let ordered = SidebarOrdering.order(try projects(["a", "b"]), by: .catalog, pinned: ["gone"], modified: [:])
    #expect(ordered.map(\.id) == ["a", "b"])
}

@Test func lastModifiedSkipsIgnoredDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ year: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date(year)], ofItemAtPath: url.path)
    }
    try write("src/a.txt", 2020)
    try write("index.html", 2019)
    try write("node_modules/x/y.js", 2025)
    try write(".git/HEAD", 2025)
    try write("dist/z.js", 2025)
    try write("build/z.js", 2025)
    try write(".DS_Store", 2025)
    #expect(SidebarOrdering.lastModified(directory: root) == date(2020))
}

@Test func lastModifiedMissingDirectoryIsNil() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(SidebarOrdering.lastModified(directory: missing) == nil)
}
