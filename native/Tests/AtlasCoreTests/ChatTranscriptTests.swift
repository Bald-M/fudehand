import Foundation
import Testing
import AtlasCore

private func line(_ json: String) -> Data { Data(json.utf8) }

@Test func chatTranscriptFollowsAReplyWithToolCalls() {
    var transcript = ChatTranscript()
    transcript.send("Read the document")
    #expect(transcript.busy)
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_get_state","args":{}}"#))
    #expect(transcript.entries.last?.status == .running)
    transcript.apply(line(#"{"type":"tool_result","id":"c1","name":"design_get_state","ok":true,"text":"[…]"}"#))
    transcript.apply(line(#"{"type":"assistant","text":"The document has 2 layers."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(!transcript.busy)
    // One call and its result are a single entry.
    #expect(transcript.entries.map(\.kind) == [.user, .tool, .assistant])
    #expect(transcript.entries.map(\.text) == ["Read the document", "design_get_state", "The document has 2 layers."])
    #expect(transcript.entries[1].status == .succeeded)
    #expect(transcript.entries[1].detail == "{}")
    #expect(transcript.entries[1].result == "[…]")
    #expect(Set(transcript.entries.map(\.id)).count == 3)
}

@Test func chatTranscriptMatchesResultsToTheirCallsById() {
    var transcript = ChatTranscript()
    transcript.send("Do two things")
    transcript.apply(line(#"{"type":"tool_call","id":"a","name":"design_undo","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_call","id":"b","name":"design_undo","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"b","name":"design_undo","ok":false,"text":"Nothing to undo"}"#))
    #expect(transcript.entries.map(\.status) == [nil, .running, .failed])
    #expect(transcript.entries[2].result == "Nothing to undo")
    // A call that never got a result does not stay "running" once the reply has ended.
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(transcript.entries.map(\.status) == [nil, .failed, .failed])
}

@Test func chatTranscriptAppendsStreamedTextToOneEntry() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"assistant_delta","text":"Hi "}"#))
    transcript.apply(line(#"{"type":"assistant_delta","text":"the"}"#))
    #expect(transcript.entries.map(\.text) == ["Hello", "Hi the"])
    let id = transcript.entries[1].id
    // The complete text replaces what was streamed, keeping the same entry.
    transcript.apply(line(#"{"type":"assistant","text":"Hi there."}"#))
    #expect(transcript.entries.map(\.text) == ["Hello", "Hi there."])
    #expect(transcript.entries[1].id == id)
    // The next round of the same reply starts a new entry.
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_undo","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"c1","name":"design_undo","ok":true,"text":"ok"}"#))
    transcript.apply(line(#"{"type":"assistant_delta","text":"Done"}"#))
    transcript.apply(line(#"{"type":"assistant","text":"Done."}"#))
    #expect(transcript.entries.map(\.kind) == [.user, .assistant, .tool, .assistant])
    #expect(transcript.entries.last?.text == "Done.")
}

@Test func chatTranscriptKeepsStreamedTextWhenStopped() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"assistant_delta","text":"Partial ans"}"#))
    transcript.apply(line(#"{"type":"done","stopped":true}"#))
    #expect(transcript.entries.map(\.kind) == [.user, .assistant, .notice])
    #expect(transcript.entries[1].text == "Partial ans")
    // A later reply does not continue the stopped entry.
    transcript.send("Again")
    transcript.apply(line(#"{"type":"assistant_delta","text":"New"}"#))
    #expect(transcript.entries.map(\.text) == ["Hello", "Partial ans", "Reply stopped", "Again", "New"])
}

@Test func chatTranscriptShowsErrorsAndStops() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"error","message":"The API key is invalid or lacks permission"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.send("Try again")
    transcript.apply(line(#"{"type":"tool_result","id":"c","name":"add_frame","ok":false,"text":"Configuration error"}"#))
    transcript.apply(line(#"{"type":"done","stopped":true}"#))
    #expect(transcript.entries.map(\.kind) == [.user, .error, .user, .tool, .notice])
    #expect(transcript.entries[1].text == "The API key is invalid or lacks permission")
    #expect(transcript.entries[3].status == .failed)
    #expect(transcript.entries[4].text == "Reply stopped")
    #expect(!transcript.busy)
}

@Test func chatTranscriptIgnoresMalformedLinesAndFails() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line("not json"))
    transcript.apply(line(#"{"type":"unknown"}"#))
    #expect(transcript.entries.count == 1)
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_undo","args":{}}"#))
    transcript.fail("The chat program exited")
    #expect(!transcript.busy)
    #expect(transcript.entries.map(\.kind) == [.user, .tool, .error])
    #expect(transcript.entries[1].status == .failed)
}

@Test func chatTranscriptRewindsToTheLastUserMessage() {
    var transcript = ChatTranscript()
    let layer = ChatContext(id: "n1", name: "Hero", type: "frame")
    transcript.send("First")
    transcript.apply(line(#"{"type":"assistant","text":"One."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.send("Second", context: [layer])
    // Not while the reply is still running.
    #expect(transcript.rewind() == nil)
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_undo","args":{}}"#))
    transcript.apply(line(#"{"type":"assistant","text":"Two."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(transcript.lastUserID == transcript.entries[2].id)
    #expect(transcript.lastReplyID == transcript.entries[4].id)
    let removed = transcript.rewind()
    #expect(removed?.text == "Second")
    #expect(removed?.context == [layer])
    #expect(transcript.entries.map(\.text) == ["First", "One."])
    // Entry ids are never reused, so views keyed by id do not mix up old and new entries.
    transcript.send("Second again")
    #expect(Set(transcript.entries.map(\.id) + [removed!.id]).count == 4)
}

@Test func chatTranscriptOffersNoReplyToRegenerateWhenTheLastTurnHasNoText() {
    var transcript = ChatTranscript()
    transcript.send("First")
    transcript.apply(line(#"{"type":"assistant","text":"One."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.send("Second")
    transcript.apply(line(#"{"type":"error","message":"boom"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    // The reply to "First" is not the one a regenerate would replace.
    #expect(transcript.lastReplyID == nil)
}

@Test func chatTranscriptListsTheMessagesToRestoreInTheHarness() {
    var transcript = ChatTranscript()
    transcript.send("Look")
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_get_state","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"c1","name":"design_get_state","ok":true,"text":"…"}"#))
    transcript.apply(line(#"{"type":"assistant","text":"One frame."}"#))
    transcript.apply(line(#"{"type":"error","message":"boom"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(transcript.messages == [["role": "user", "text": "Look"], ["role": "assistant", "text": "One frame."]])
    #expect(transcript.title == "Look")
    var long = ChatTranscript()
    long.send("  A very long first line that goes on and on past the limit of the title\nsecond line")
    #expect(long.title == "A very long first line that goes on and on past th…")
    #expect(ChatTranscript().title == "")
}

@Test func chatTranscriptGroupsConsecutiveToolCallsIntoSteps() {
    var transcript = ChatTranscript()
    transcript.send("Build it")
    transcript.apply(line(#"{"type":"tool_call","id":"a","name":"design_get_state","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"a","name":"design_get_state","ok":true,"text":"…"}"#))
    transcript.apply(line(#"{"type":"assistant","text":"Creating."}"#))
    for id in ["b", "c", "d"] {
        transcript.apply(line(#"{"type":"tool_call","id":"\#(id)","name":"design_create_node","args":{}}"#))
        transcript.apply(line(#"{"type":"tool_result","id":"\#(id)","name":"design_create_node","ok":true,"text":"…"}"#))
    }
    let groups = transcript.groups
    #expect(groups.map(\.entries.count) == [1, 1, 1, 3])
    #expect(groups.map(\.isSteps) == [false, false, false, true])
    #expect(groups.map(\.id) == [0, 1, 2, 3])
}

@Test func chatTranscriptIsRestoredFromSavedEntries() throws {
    var transcript = ChatTranscript()
    transcript.send("Look", context: [ChatContext(id: "n1", name: "Hero", type: "frame")])
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_get_node","args":{"id":"n1"}}"#))
    let saved = try JSONEncoder().encode(transcript.entries)
    let restored = ChatTranscript(entries: try JSONDecoder().decode([ChatEntry].self, from: saved))
    #expect(!restored.busy)
    #expect(restored.entries.map(\.text) == ["Look", "design_get_node"])
    #expect(restored.entries[0].context.map(\.name) == ["Hero"])
    // A call that was still running when it was saved can no longer finish.
    #expect(restored.entries[1].status == .failed)
    var next = restored
    next.send("More")
    #expect(Set(next.entries.map(\.id)).count == 3)
}

@Test func chatTranscriptAttachesUsageToTheLastTextOfTheReply() {
    var transcript = ChatTranscript()
    transcript.send("Look")
    transcript.apply(line(#"{"type":"assistant","text":"Checking"}"#))
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_get_state","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"c1","name":"design_get_state","ok":true,"text":"[]"}"#))
    transcript.apply(line(#"{"type":"assistant","text":"Done"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"usage":{"input":250,"output":30,"cached":90}}"#))
    #expect(transcript.entries.map(\.usage) == [nil, nil, nil, ChatUsage(input: 250, output: 30, cached: 90)])
    #expect(transcript.entries[3].usage?.total == 280)
}

@Test func chatTranscriptDropsUsageWhenTheReplyHasNoText() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"assistant","text":"Hi"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.send("Again")
    transcript.apply(line(#"{"type":"error","message":"Quota exceeded or too many requests"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"usage":{"input":100,"output":10,"cached":0}}"#))
    // The earlier reply is not given the usage of this one.
    #expect(transcript.entries.allSatisfy { $0.usage == nil })
    #expect(!transcript.busy)
}

@Test func chatTranscriptKeepsUsageOfAStoppedReply() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"assistant_delta","text":"Half"}"#))
    transcript.apply(line(#"{"type":"done","stopped":true,"usage":{"input":100,"output":10,"cached":0}}"#))
    #expect(transcript.entries.map(\.kind) == [.user, .assistant, .notice])
    #expect(transcript.entries[1].usage == ChatUsage(input: 100, output: 10, cached: 0))
}

@Test func chatTranscriptIgnoresMalformedUsage() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"assistant","text":"Hi"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"usage":{"input":"x","output":10,"cached":0}}"#))
    #expect(transcript.entries[1].usage == nil)
    #expect(!transcript.busy)
}

@Test func chatUsageIsSavedAndOlderConversationsStillLoad() throws {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"assistant","text":"Hi"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"usage":{"input":250,"output":30,"cached":90}}"#))
    let restored = try JSONDecoder().decode([ChatEntry].self, from: JSONEncoder().encode(transcript.entries))
    #expect(restored[1].usage == ChatUsage(input: 250, output: 30, cached: 90))
    // Saved before usage was recorded.
    let older = try JSONDecoder().decode([ChatEntry].self, from: line(#"[{"id":0,"kind":"assistant","text":"Old","context":[]}]"#))
    #expect(older[0].usage == nil)
}

@Test func chatUsageFormatsCompactCounts() {
    #expect([0, 856, 999, 1000, 30_349, 999_949, 999_950, 1_234_567].map(ChatUsage.compact)
        == ["0", "856", "999", "1.0K", "30.3K", "999.9K", "1.0M", "1.2M"])
}

@Test func toolSubjectNamesWhatACallActsOn() {
    func subject(_ args: String) -> String? {
        ChatEntry.toolSubject(arguments: args) { ["n1": "Hero", "n2": "Title"][$0] }
    }
    #expect(subject(#"{"node":{"type":"frame","name":"Home"}}"#) == "Home")
    #expect(subject(#"{"id":"n1","changes":{"name":"Renamed"}}"#) == "Hero")
    #expect(subject(#"{"ids":["n1","n2","gone"]}"#) == "Hero, Title")
    #expect(subject(#"{"path":"/Users/me/Designs/shop.uiatlas"}"#) == "shop.uiatlas")
    #expect(subject(#"{"scale":1.5}"#) == "150%")
    #expect(subject(#"{"id":"gone"}"#) == nil)
    #expect(subject("{}") == nil)
    #expect(subject("not json") == nil)
}
