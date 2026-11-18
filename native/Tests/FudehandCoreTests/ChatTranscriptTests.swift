import Foundation
import Testing
import FudehandCore

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
    #expect(subject(#"{"path":"/Users/me/Designs/shop.fudehand"}"#) == "shop.fudehand")
    #expect(subject(#"{"scale":1.5}"#) == "150%")
    #expect(subject(#"{"id":"gone"}"#) == nil)
    #expect(subject("{}") == nil)
    #expect(subject("not json") == nil)
}

private let questionEvent = #"{"type":"question","id":"q1","question":"How many entries?","detail":"It decides the icon size.","options":[{"label":"3 entries","description":"Roomy"},{"label":"4 entries"}]}"#

private func asking() -> ChatTranscript {
    var transcript = ChatTranscript()
    transcript.send("Add a bottom navigation")
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_get_state","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"c1","name":"design_get_state","ok":true,"text":"[…]"}"#))
    transcript.apply(line(questionEvent))
    return transcript
}

@Test func chatTranscriptShowsAQuestionAndWaitsForTheAnswer() {
    var transcript = asking()
    #expect(transcript.busy)
    #expect(transcript.waiting)
    let entry = transcript.entries.last
    #expect(entry?.kind == .question)
    #expect(entry?.text == "How many entries?")
    #expect(entry?.question?.detail == "It decides the icon size.")
    #expect(entry?.question?.options == [ChatQuestion.Option(label: "3 entries", description: "Roomy"), ChatQuestion.Option(label: "4 entries", description: nil)])
    #expect(entry?.question?.state == .pending)
    #expect(transcript.pendingQuestion?.id == entry?.id)
    // A question is its own row, not one of the folded tool steps.
    #expect(transcript.groups.map(\.entries.count) == [1, 1, 1])

    let message = transcript.answer("3 entries")
    #expect(message?["type"] as? String == "answer")
    #expect(message?["id"] as? String == "q1")
    #expect(message?["question"] as? String == "How many entries?")
    #expect(message?["text"] as? String == "3 entries")
    #expect(message?["skipped"] == nil)
    #expect(transcript.entries.last?.question?.state == .answered("3 entries"))
    #expect(!transcript.waiting)
    #expect(transcript.busy)
    // Nothing is left to answer.
    #expect(transcript.answer("4 entries") == nil)
}

@Test func chatTranscriptRecordsASkippedQuestion() {
    var transcript = asking()
    let message = transcript.answer(nil)
    #expect(message?["skipped"] as? Bool == true)
    #expect(message?["text"] == nil)
    #expect(transcript.entries.last?.question?.state == .skipped)
}

@Test func chatTranscriptCancelsTheQuestionWhenTheReplyIsStopped() {
    var transcript = asking()
    transcript.apply(line(#"{"type":"done","stopped":true}"#))
    #expect(!transcript.busy)
    #expect(!transcript.waiting)
    #expect(transcript.entries.first { $0.kind == .question }?.question?.state == .cancelled)
    #expect(transcript.entries.last?.kind == .notice)
}

@Test func chatTranscriptKeepsTheQuestionWhenTheHarnessGoesAway() throws {
    var transcript = asking()
    transcript.suspend()
    #expect(!transcript.busy)
    #expect(transcript.waiting)
    // No "Reply stopped" notice: the reply is only waiting for the answer.
    #expect(transcript.entries.last?.kind == .question)

    // Saved and reopened, the question is still there to answer.
    let saved = try JSONEncoder().encode(transcript.entries)
    var restored = ChatTranscript(entries: try JSONDecoder().decode([ChatEntry].self, from: saved))
    #expect(restored.waiting)
    #expect(!restored.busy)
    #expect(restored.entries == transcript.entries)
    // The history given to a new harness leaves the open question out; the answer restates it.
    #expect(restored.messages == [["role": "user", "text": "Add a bottom navigation"]])
    let message = restored.answer("4 entries")
    #expect(message?["id"] as? String == "q1")
    // Answering starts the reply again.
    #expect(restored.busy)
    #expect(restored.messages == [["role": "user", "text": "Add a bottom navigation"], ["role": "assistant", "text": "How many entries?"], ["role": "user", "text": "4 entries"]])
}

@Test func chatTranscriptCancelsAnOpenQuestionWhenAnotherMessageIsSentOrTheTurnIsRewound() {
    var transcript = asking()
    transcript.suspend()
    transcript.send("Never mind, make it a tab bar")
    #expect(transcript.entries.first { $0.kind == .question }?.question?.state == .cancelled)
    #expect(transcript.pendingQuestion == nil)

    var rewound = asking()
    rewound.suspend()
    #expect(rewound.rewind()?.text == "Add a bottom navigation")
    #expect(rewound.entries.isEmpty)
}

@Test func chatEntriesSavedBeforeQuestionsExistedStillLoad() throws {
    let saved = #"[{"id":0,"kind":"user","text":"Hello","context":[]},{"id":1,"kind":"tool","text":"design_undo","status":"succeeded","context":[],"call":"c1"}]"#
    let entries = try JSONDecoder().decode([ChatEntry].self, from: Data(saved.utf8))
    #expect(entries.map(\.question) == [nil, nil])
}

@Test func chatTranscriptKeepsTheSuggestedNextMessageUntilTheNextMessageIsSent() throws {
    var transcript = ChatTranscript()
    transcript.send("Make the title bigger")
    transcript.apply(line(#"{"type":"assistant","text":"Done."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(transcript.suggestion == nil)
    transcript.apply(line(#"{"type":"suggestion","text":"Make the subtitle bigger too"}"#))
    #expect(transcript.suggestion == "Make the subtitle bigger too")
    // The suggestion is not a message: it is neither shown in the transcript nor saved with the conversation.
    #expect(transcript.entries.map(\.kind) == [.user, .assistant])
    let saved = try JSONEncoder().encode(ChatConversation(id: UUID(), transcript: transcript, updatedAt: Date()))
    #expect(!String(decoding: saved, as: UTF8.self).contains("subtitle"))
    transcript.send("Something else")
    #expect(transcript.suggestion == nil)
}

@Test func chatTranscriptIgnoresASuggestionThatArrivesDuringAReplyOrIsEmpty() {
    var transcript = ChatTranscript()
    transcript.send("First")
    // Predicted for the conversation before this message was sent.
    transcript.apply(line(#"{"type":"suggestion","text":"Stale"}"#))
    #expect(transcript.suggestion == nil)
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.apply(line(#"{"type":"suggestion","text":""}"#))
    #expect(transcript.suggestion == nil)
}

@Test func chatTranscriptDropsTheSuggestionWhenTheLastMessageIsTakenBack() {
    var transcript = ChatTranscript()
    transcript.send("First")
    transcript.apply(line(#"{"type":"assistant","text":"Done."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.apply(line(#"{"type":"suggestion","text":"Next"}"#))
    #expect(transcript.rewind()?.text == "First")
    #expect(transcript.suggestion == nil)
}

@Test func chatTranscriptTracksTheContextTheLastReplyReported() {
    var transcript = ChatTranscript()
    #expect(transcript.contextTokens == nil)
    transcript.send("Look")
    transcript.apply(line(#"{"type":"assistant","text":"One frame."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"usage":{"input":250,"output":30,"cached":0},"context":170}"#))
    #expect(transcript.contextTokens == 170)
    transcript.send("Again")
    transcript.apply(line(#"{"type":"assistant","text":"Still one."}"#))
    // A reply that reports no context leaves the last known one.
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(transcript.contextTokens == 170)
    transcript.send("More")
    transcript.apply(line(#"{"type":"assistant","text":"Two now."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"context":420}"#))
    #expect(transcript.contextTokens == 420)
    // Taking the last message back returns to what the conversation held before it.
    _ = transcript.rewind()
    #expect(transcript.contextTokens == 170)
    // It is saved with the conversation; one saved before this was recorded has none.
    let restored = try! JSONDecoder().decode([ChatEntry].self, from: JSONEncoder().encode(transcript.entries))
    #expect(ChatTranscript(entries: restored).contextTokens == 170)
    let older = try! JSONDecoder().decode([ChatEntry].self, from: Data(#"[{"id":0,"kind":"assistant","text":"Hi","context":[]}]"#.utf8))
    #expect(ChatTranscript(entries: older).contextTokens == nil)
}

@Test func chatTranscriptCompactsIntoASummaryAndKeepsTheMessages() {
    var transcript = ChatTranscript()
    #expect(!transcript.canCompact)
    transcript.send("Make the header blue")
    #expect(!transcript.canCompact)
    transcript.apply(line(#"{"type":"assistant","text":"Done."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"usage":{"input":900,"output":20,"cached":0},"context":920}"#))
    #expect(transcript.canCompact)

    transcript.compact()
    #expect(transcript.busy)
    #expect(transcript.compacting)
    transcript.apply(line(#"{"type":"compacted","summary":"The header is blue."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"usage":{"input":950,"output":12,"cached":900},"context":12}"#))
    #expect(!transcript.busy)
    #expect(!transcript.compacting)
    // Every earlier message is still shown, followed by the summary.
    #expect(transcript.entries.map(\.kind) == [.user, .assistant, .summary])
    #expect(transcript.entries.map(\.text) == ["Make the header blue", "Done.", "The header is blue."])
    #expect(transcript.contextTokens == 12)
    // The summary request's usage is not shown as the earlier reply's.
    #expect(transcript.entries[1].usage == ChatUsage(input: 900, output: 20, cached: 0))
    #expect(transcript.entries[2].usage == nil)
    // The harness is restored from the summary on, not from the messages it replaced.
    #expect(transcript.messages == [["role": "summary", "text": "The header is blue."]])
    // Nothing new to compact until the conversation goes on.
    #expect(!transcript.canCompact)

    transcript.send("Which color?")
    transcript.apply(line(#"{"type":"assistant","text":"Blue."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"context":300}"#))
    #expect(transcript.messages == [["role": "summary", "text": "The header is blue."], ["role": "user", "text": "Which color?"], ["role": "assistant", "text": "Blue."]])
    #expect(transcript.contextTokens == 300)
    #expect(transcript.canCompact)
    #expect(transcript.title == "Make the header blue")
    #expect(transcript.groups.map(\.entries.count) == [1, 1, 1, 1, 1])
}

@Test func chatTranscriptKeepsEverythingWhenCompactingFailsOrIsStopped() {
    var transcript = ChatTranscript()
    transcript.send("Make the header blue")
    transcript.apply(line(#"{"type":"assistant","text":"Done."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"context":920}"#))
    let before = transcript.messages

    transcript.compact()
    transcript.apply(line(#"{"type":"error","message":"Model API error (HTTP 500): overloaded"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(!transcript.busy && !transcript.compacting)
    #expect(transcript.entries.map(\.kind) == [.user, .assistant, .error])
    #expect(transcript.entries.last?.text == "Could not compact the context: Model API error (HTTP 500): overloaded")
    #expect(transcript.messages == before)
    #expect(transcript.contextTokens == 920)

    transcript.compact()
    transcript.apply(line(#"{"type":"done","stopped":true}"#))
    #expect(!transcript.busy && !transcript.compacting)
    #expect(transcript.entries.last?.kind == .notice)
    #expect(transcript.entries.last?.text == "Compacting stopped")
    #expect(transcript.messages == before)

    // A harness that exits while compacting fails the same way.
    transcript.compact()
    transcript.fail("The chat process exited unexpectedly")
    #expect(!transcript.busy && !transcript.compacting)
    #expect(transcript.messages == before)

    // Not while a reply is running.
    transcript.send("Hi")
    transcript.compact()
    #expect(!transcript.compacting)
    // An error of an ordinary reply is shown as it is.
    transcript.apply(line(#"{"type":"error","message":"Quota exceeded or too many requests"}"#))
    #expect(transcript.entries.last?.text == "Quota exceeded or too many requests")
}

@Test func aCompactionThatReportsNoUsageDoesNotKeepTheOldContext() {
    var transcript = ChatTranscript()
    transcript.send("Make the header blue")
    transcript.apply(line(#"{"type":"assistant","text":"Done."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"context":7900}"#))
    transcript.compact()
    transcript.apply(line(#"{"type":"compacted","summary":"The header is blue."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    // What the earlier reply reported no longer describes the conversation.
    #expect(transcript.contextTokens == nil)
}

@Test func rewindingAMessageSentBeforeACompactionTakesTheCompactionBack() {
    var transcript = ChatTranscript()
    transcript.send("Make the header blue")
    transcript.apply(line(#"{"type":"assistant","text":"Done."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"context":920}"#))
    transcript.send("And the footer")
    transcript.apply(line(#"{"type":"assistant","text":"Done too."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"context":1800}"#))
    transcript.compact()
    transcript.apply(line(#"{"type":"compacted","summary":"Header and footer are blue."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false,"context":12}"#))
    #expect(transcript.rewind()?.text == "And the footer")
    // The summary went with it: the harness is given the messages up to that point again.
    #expect(transcript.messages == [["role": "user", "text": "Make the header blue"], ["role": "assistant", "text": "Done."]])
    #expect(transcript.contextTokens == 920)
}

@Test func contextUsageGivesTheShareOfTheWindowAndWarnsNearTheLimit() {
    #expect(ContextUsage(used: 0, window: 128_000).fraction == 0)
    #expect(ContextUsage(used: 32_000, window: 128_000).fraction == 0.25)
    #expect(ContextUsage(used: 32_000, window: 128_000).level == .normal)
    #expect(ContextUsage(used: 96_000, window: 128_000).level == .high)
    #expect(ContextUsage(used: 115_200, window: 128_000).level == .critical)
    // Never more than full, whatever the API counted.
    #expect(ContextUsage(used: 200_000, window: 128_000).fraction == 1)
    #expect(ContextUsage(used: 200_000, window: 128_000).level == .critical)
    // The same usage against another model's window.
    #expect(ContextUsage(used: 96_000, window: 1_048_576).level == .normal)
    // Without a known window there is no share and nothing to warn about.
    #expect(ContextUsage(used: 96_000, window: nil).fraction == nil)
    #expect(ContextUsage(used: 96_000, window: nil).level == .normal)
    #expect(ContextUsage(used: 96_000, window: 0).fraction == nil)
    #expect(ContextUsage(used: 96_000, window: 128_000).percent == 75)
    #expect(ContextUsage(used: 100, window: 128_000).percent == 1)
    #expect(ContextUsage(used: 0, window: 128_000).percent == 0)
}
