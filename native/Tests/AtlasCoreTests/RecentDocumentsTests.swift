import Foundation
import Testing
import AtlasCore

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func recentDocumentsPutTheLatestFirstWithoutDuplicates() {
    var recents = RecentDocuments()
    recents.record("/a.uiatlas", at: date(1))
    recents.record("/b.uiatlas", at: date(2))
    recents.record("/a.uiatlas", at: date(3))
    #expect(recents.items.map(\.path) == ["/a.uiatlas", "/b.uiatlas"])
    #expect(recents.items.first?.openedAt == date(3))
}

@Test func recentDocumentsKeepAtMostTen() {
    var recents = RecentDocuments()
    for index in 0..<12 { recents.record("/\(index).uiatlas", at: date(Double(index))) }
    #expect(recents.items.count == RecentDocuments.limit)
    #expect(recents.items.first?.path == "/11.uiatlas")
    #expect(recents.items.last?.path == "/2.uiatlas")
}

@Test func recentDocumentsRemoveAndClear() {
    var recents = RecentDocuments()
    recents.record("/a.uiatlas", at: date(1))
    recents.record("/b.uiatlas", at: date(2))
    recents.remove("/a.uiatlas")
    #expect(recents.items.map(\.path) == ["/b.uiatlas"])
    recents.clear()
    #expect(recents.items.isEmpty)
}

@Test func recentDocumentsMarkMissingFiles() {
    var recents = RecentDocuments()
    recents.record("/gone.uiatlas", at: date(1))
    recents.record("/here.uiatlas", at: date(2))
    let entries = recents.entries { $0 == "/here.uiatlas" }
    #expect(entries.map(\.path) == ["/here.uiatlas", "/gone.uiatlas"])
    #expect(entries.map(\.available) == [true, false])
}

@Test func recentDocumentsRoundTripAndTolerateBadData() {
    var recents = RecentDocuments()
    recents.record("/a.uiatlas", at: date(1))
    #expect(RecentDocuments(data: recents.encoded()) == recents)
    #expect(RecentDocuments(data: Data("not json".utf8)).items.isEmpty)
    #expect(RecentDocuments(data: nil).items.isEmpty)
    // Entries broken by hand: duplicates and anything beyond the limit are dropped on read.
    let items = (0..<12).map { RecentDocument(path: "/\($0 % 11).uiatlas", openedAt: date(Double(20 - $0))) }
    let data = try! JSONEncoder().encode(items)
    let loaded = RecentDocuments(data: data)
    #expect(loaded.items.count == RecentDocuments.limit)
    #expect(Set(loaded.items.map(\.path)).count == loaded.items.count)
}
