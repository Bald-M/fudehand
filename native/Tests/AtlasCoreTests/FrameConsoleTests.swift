import Foundation
import Testing
import AtlasCore

@Test func frameConsoleKeepsTheMostRecentEntriesUpToCapacity() {
    var console = FrameConsole(capacity: 3)
    for index in 1...5 {
        console.append(level: "log", source: "console", message: "第 \(index) 条", time: Date(timeIntervalSince1970: Double(index)))
    }
    #expect(console.recent(10).map(\.message) == ["第 3 条", "第 4 条", "第 5 条"])
    #expect(console.recent(2).map(\.message) == ["第 4 条", "第 5 条"])
    #expect(console.dropped == 2)
}

@Test func frameConsoleTruncatesLongMessages() {
    var console = FrameConsole(capacity: 3, maximumLength: 5)
    console.append(level: "error", source: "exception", message: "一二三四五六七", time: Date())
    #expect(console.recent(1).first?.message == "一二三四五…")
}

@Test func frameConsoleEncodesEntriesForTheControlChannel() throws {
    var console = FrameConsole()
    console.append(level: "warn", source: "console", message: "注意", time: Date(timeIntervalSince1970: 1.5))
    let entry = try #require(console.recent(1).first)
    #expect(entry.json["level"] as? String == "warn")
    #expect(entry.json["source"] as? String == "console")
    #expect(entry.json["message"] as? String == "注意")
    #expect(entry.json["time"] as? Double == 1500)
}
