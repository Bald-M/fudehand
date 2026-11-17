import Foundation
import Testing
import AtlasCore

private func line(_ json: String) -> Data { Data(json.utf8) }

@Test func chatTranscriptFollowsAReplyWithToolCalls() {
    var transcript = ChatTranscript()
    transcript.send("读取文档")
    #expect(transcript.busy)
    transcript.apply(line(#"{"type":"tool_call","id":"c1","name":"design_get_state","args":{}}"#))
    transcript.apply(line(#"{"type":"tool_result","id":"c1","name":"design_get_state","ok":true,"text":"[…]"}"#))
    transcript.apply(line(#"{"type":"assistant","text":"文档里有 2 个图层。"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    #expect(!transcript.busy)
    #expect(transcript.entries.map(\.kind) == [.user, .toolCall, .toolResult(ok: true), .assistant])
    #expect(transcript.entries.map(\.text) == ["读取文档", "design_get_state", "design_get_state", "文档里有 2 个图层。"])
    #expect(transcript.entries[1].detail == "{}")
    #expect(transcript.entries[2].detail == "[…]")
    #expect(Set(transcript.entries.map(\.id)).count == 4)
}

@Test func chatTranscriptShowsErrorsAndStops() {
    var transcript = ChatTranscript()
    transcript.send("你好")
    transcript.apply(line(#"{"type":"error","message":"API key 无效或无权限"}"#))
    transcript.apply(line(#"{"type":"done","stopped":false}"#))
    transcript.send("再试")
    transcript.apply(line(#"{"type":"tool_result","id":"c","name":"add_frame","ok":false,"text":"配置错误"}"#))
    transcript.apply(line(#"{"type":"done","stopped":true}"#))
    #expect(transcript.entries.map(\.kind) == [.user, .error, .user, .toolResult(ok: false), .notice])
    #expect(transcript.entries[1].text == "API key 无效或无权限")
    #expect(transcript.entries[4].text == "已停止回复")
    #expect(!transcript.busy)
}

@Test func chatTranscriptIgnoresMalformedLinesAndClears() {
    var transcript = ChatTranscript()
    transcript.send("你好")
    transcript.apply(line("not json"))
    transcript.apply(line(#"{"type":"unknown"}"#))
    #expect(transcript.entries.count == 1)
    transcript.fail("对话程序已退出")
    #expect(!transcript.busy)
    #expect(transcript.entries.last?.kind == .error)
    transcript.clear()
    #expect(transcript.entries.isEmpty)
    #expect(!transcript.busy)
}
