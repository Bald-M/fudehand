import Foundation
import Testing
import AtlasCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-chats-\(UUID().uuidString)")
}

private func conversation(_ text: String, at seconds: TimeInterval, id: UUID = UUID()) -> ChatConversation {
    var transcript = ChatTranscript()
    transcript.send(text)
    transcript.apply(Data(#"{"type":"assistant","text":"Reply"}"#.utf8))
    transcript.apply(Data(#"{"type":"done","stopped":false}"#.utf8))
    return ChatConversation(id: id, transcript: transcript, updatedAt: Date(timeIntervalSince1970: seconds))
}

@Test func chatHistorySavesAndReloadsConversations() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = ChatHistory(directory: directory)
    #expect(history.list() == [])
    let first = conversation("Build a login screen", at: 100)
    let second = conversation("Make the button blue", at: 200)
    try history.save(first)
    try history.save(second)
    // Newest first, read back by another instance as after a relaunch.
    let reopened = ChatHistory(directory: directory)
    #expect(reopened.list().map(\.title) == ["Make the button blue", "Build a login screen"])
    #expect(reopened.list().map(\.id) == [second.id, first.id])
    #expect(reopened.load(first.id)?.entries.map(\.text) == ["Build a login screen", "Reply"])
}

@Test func chatHistoryOverwritesDeletesAndSkipsUnreadableFiles() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = ChatHistory(directory: directory)
    let id = UUID()
    try history.save(conversation("Old text", at: 100, id: id))
    try history.save(conversation("New text", at: 300, id: id))
    try history.save(conversation("Other", at: 200))
    #expect(history.list().map(\.title) == ["New text", "Other"])
    try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
    #expect(history.list().count == 2)
    history.delete(id)
    #expect(history.list().map(\.title) == ["Other"])
    #expect(history.load(id) == nil)
}

@Test func chatHistoryKeepsOnlyTheNewestConversations() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = ChatHistory(directory: directory, limit: 3)
    for index in 1...5 { try history.save(conversation("Chat \(index)", at: TimeInterval(index))) }
    #expect(history.list().map(\.title) == ["Chat 5", "Chat 4", "Chat 3"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
}

@Test func scrollFollowStaysAtTheBottomUntilTheUserScrollsUp() {
    var follow = ChatScrollFollow()
    #expect(follow.following)
    follow.update(offset: 0, contentHeight: 300, viewportHeight: 500)
    follow.update(offset: 500, contentHeight: 1000, viewportHeight: 500)
    #expect(follow.following)
    // New text makes the content taller before the view has scrolled; that alone does not stop following.
    follow.update(offset: 500, contentHeight: 1200, viewportHeight: 500)
    #expect(follow.following && !follow.atBottom)
    follow.update(offset: 700, contentHeight: 1200, viewportHeight: 500)
    #expect(follow.atBottom)
    // The user scrolls up.
    follow.update(offset: 400, contentHeight: 1200, viewportHeight: 500)
    #expect(!follow.following)
    follow.update(offset: 400, contentHeight: 1500, viewportHeight: 500)
    follow.update(offset: 600, contentHeight: 1500, viewportHeight: 500)
    #expect(!follow.following)
    // Back within reach of the bottom.
    follow.update(offset: 990, contentHeight: 1500, viewportHeight: 500)
    #expect(follow.following)
}
