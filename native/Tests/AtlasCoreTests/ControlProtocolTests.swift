import Foundation
import Testing
import AtlasCore

private func parse(_ line: String) -> Result<ControlRequest, ControlFailure> {
    ControlProtocol.parse(Data(line.utf8))
}

private func object(_ data: Data) throws -> [String: Any] {
    #expect(data.last == UInt8(ascii: "\n"))
    #expect(!data.dropLast().contains(UInt8(ascii: "\n")))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func controlProtocolParsesEveryCommand() throws {
    let cases: [(String, ControlCommand)] = [
        (#"{"id":1,"command":"get_state"}"#, .getState),
        (#"{"id":2,"command":"select_project","args":{"project":"still"}}"#, .selectProject("still")),
        (#"{"id":3,"command":"focus_frame","args":{"frame":"mobile"}}"#, .focusFrame("mobile")),
        (#"{"id":4,"command":"fit_all"}"#, .fitAll),
        (#"{"id":5,"command":"zoom","args":{"scale":0.5}}"#, .zoom(0.5)),
        (#"{"id":6,"command":"zoom","args":{"scale":2}}"#, .zoom(2)),
        (#"{"id":7,"command":"reset","args":{}}"#, .reset),
        (#"{"id":8,"command":"restart_preview"}"#, .restartPreview),
        (#"{"id":"s","command":"frame_snapshot","args":{"frame":"web"}}"#, .frameSnapshot("web")),
    ]
    for (line, command) in cases {
        #expect(try parse(line).get().command == command)
    }
    #expect(try parse(#"{"id":"s","command":"fit_all"}"#).get().id == .string("s"))
    #expect(try parse(#"{"id":9,"command":"fit_all"}"#).get().id == .int(9))
    #expect(try parse(#"{"command":"fit_all"}"#).get().id == nil)
    #expect(try parse(#"{"id":1e300,"command":"fit_all"}"#).get().id == nil)
}

@Test func controlProtocolRejectsInvalidRequestsInChinese() {
    let cases: [(String, String)] = [
        ("not json", "请求不是有效 JSON"),
        ("[1,2]", "请求不是有效 JSON"),
        (#"{"id":1}"#, "缺少参数：command"),
        (#"{"id":1,"command":3}"#, "参数类型错误：command"),
        (#"{"id":1,"command":"drag_frame"}"#, "未知命令：drag_frame"),
        (#"{"id":1,"command":"focus_frame"}"#, "缺少参数：frame"),
        (#"{"id":1,"command":"focus_frame","args":{"frame":7}}"#, "参数类型错误：frame"),
        (#"{"id":1,"command":"select_project","args":{}}"#, "缺少参数：project"),
        (#"{"id":1,"command":"zoom","args":{"scale":"big"}}"#, "参数类型错误：scale"),
        (#"{"id":1,"command":"zoom","args":{"scale":0}}"#, "参数类型错误：scale"),
        (#"{"id":1,"command":"zoom","args":{"scale":true}}"#, "参数类型错误：scale"),
        (#"{"id":1,"command":"fit_all","args":[]}"#, "参数类型错误：args"),
    ]
    for (line, message) in cases {
        guard case .failure(let failure) = parse(line) else { Issue.record("应拒绝：\(line)"); continue }
        #expect(failure.message == message, "\(line)")
    }
    guard case .failure(let failure) = parse(#"{"id":4,"command":"nope"}"#) else { Issue.record("应拒绝"); return }
    #expect(failure.id == .int(4))
}

@Test func controlProtocolEncodesSingleLineResponses() throws {
    let success = try object(ControlProtocol.success(id: .int(3), result: ["project": "still", "text": "a\nb"]))
    #expect(success["id"] as? Int == 3)
    #expect(success["ok"] as? Bool == true)
    #expect((success["result"] as? [String: Any])?["text"] as? String == "a\nb")
    let failure = try object(ControlProtocol.failure(id: .string("x"), message: "未知命令：nope"))
    #expect(failure["id"] as? String == "x")
    #expect(failure["ok"] as? Bool == false)
    #expect(failure["error"] as? String == "未知命令：nope")
    let anonymous = try object(ControlProtocol.failure(id: nil, message: "请求不是有效 JSON"))
    #expect(anonymous["id"] is NSNull)
}
