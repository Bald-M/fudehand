import Foundation
import Testing
import AtlasCore

private func line(_ json: String) -> Data { Data(json.utf8) }

@Test func chatTranscriptFollowsAReplyWithToolCalls() {
    var transcript = ChatTranscript()
    transcript.send("Read the document")
    #expect(transcript.busy)
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_get_state","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"c1","name":"design_get_state","ok":true,"text":"[…]"}"#))
    transcript.apply(line(#"{"type":"assistant","text":"The document has 2 layers."}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(!transcript.busy)
    #expect(transcript.entries.map(\.kind) == [.user, .toolCall, .toolResult(ok: true), .assistant])
    #expect(transcript.entries.map(\.text) == ["Read the document", "design_get_state", "design_get_state", "The document has 2 layers."])
    #expect(transcript.entries[1].detail == "{}")
    #expect(transcript.entries[2].detail == "[…]")
    #expect(Set(transcript.entries.map(\.id)).count == 4)
}

@Test func chatTranscriptShowsErrorsAndStops() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line(#"{"type":"error","message":"The API key is invalid or lacks permission"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.send("Try again")
    transcript.apply(line(#"{"type":"tool_result","id":"c","name":"add_frame","ok":false,"text":"Configuration error"}"#))
    transcript.apply(line(#"{"type":"done","stopped":true}"#))
    #expect(transcript.entries.map(\.kind) == [.user, .error, .user, .toolResult(ok: false), .notice])
    #expect(transcript.entries[1].text == "The API key is invalid or lacks permission")
    #expect(transcript.entries[4].text == "Reply stopped")
    #expect(!transcript.busy)
}

@Test func chatTranscriptIgnoresMalformedLinesAndClears() {
    var transcript = ChatTranscript()
    transcript.send("Hello")
    transcript.apply(line("not json"))
    transcript.apply(line(#"{"type":"unknown"}"#))
    #expect(transcript.entries.count == 1)
    transcript.fail("The chat program exited")
    #expect(!transcript.busy)
    #expect(transcript.entries.last?.kind == .error)
    transcript.clear()
    #expect(transcript.entries.isEmpty)
    #expect(!transcript.busy)
}
