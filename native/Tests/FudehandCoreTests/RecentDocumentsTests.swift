import Foundation
import Testing
import FudehandCore

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func recentDocumentsPutTheLatestFirstWithoutDuplicates() {
    var recents = RecentDocuments()
    recents.record("/a.fudehand", at: date(1))
    recents.record("/b.fudehand", at: date(2))
    recents.record("/a.fudehand", at: date(3))
    #expect(recents.items.map(\.path) == ["/a.fudehand", "/b.fudehand"])
    #expect(recents.items.first?.openedAt == date(3))
}

@Test func recentDocumentsKeepAtMostTen() {
    var recents = RecentDocuments()
    for index in 0..<12 { recents.record("/\(index).fudehand", at: date(Double(index))) }
    #expect(recents.items.count == RecentDocuments.limit)
    #expect(recents.items.first?.path == "/11.fudehand")
    #expect(recents.items.last?.path == "/2.fudehand")
}

@Test func recentDocumentsRemoveAndClear() {
    var recents = RecentDocuments()
    recents.record("/a.fudehand", at: date(1))
    recents.record("/b.fudehand", at: date(2))
    recents.remove("/a.fudehand")
    #expect(recents.items.map(\.path) == ["/b.fudehand"])
    recents.clear()
    #expect(recents.items.isEmpty)
}

@Test func recentDocumentsMarkMissingFiles() {
    var recents = RecentDocuments()
    recents.record("/gone.fudehand", at: date(1))
    recents.record("/here.fudehand", at: date(2))
    let entries = recents.entries { $0 == "/here.fudehand" }
    #expect(entries.map(\.path) == ["/here.fudehand", "/gone.fudehand"])
    #expect(entries.map(\.available) == [true, false])
}

@Test func recentDocumentsRoundTripAndTolerateBadData() {
    var recents = RecentDocuments()
    recents.record("/a.fudehand", at: date(1))
    #expect(RecentDocuments(data: recents.encoded()) == recents)
    #expect(RecentDocuments(data: Data("not json".utf8)).items.isEmpty)
    #expect(RecentDocuments(data: nil).items.isEmpty)
    // Entries broken by hand: duplicates and anything beyond the limit are dropped on read.
    let items = (0..<12).map { RecentDocument(path: "/\($0 % 11).fudehand", openedAt: date(Double(20 - $0))) }
    let data = try! JSONEncoder().encode(items)
    let loaded = RecentDocuments(data: data)
    #expect(loaded.items.count == RecentDocuments.limit)
    #expect(Set(loaded.items.map(\.path)).count == loaded.items.count)
}
