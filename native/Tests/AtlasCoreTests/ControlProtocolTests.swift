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
        (#"{"id":2,"command":"get_document"}"#, .getDocument),
        (#"{"id":3,"command":"get_node","args":{"id":"card"}}"#, .getNode("card")),
        (#"{"id":4,"command":"create_node","args":{"node":{"type":"rectangle"}}}"#,
         .createNode(parent: nil, index: nil, node: JSONObject(["type": "rectangle"]))),
        (#"{"id":5,"command":"create_node","args":{"parent":"f","index":0,"node":{"type":"text"}}}"#,
         .createNode(parent: "f", index: 0, node: JSONObject(["type": "text"]))),
        (#"{"id":6,"command":"update_node","args":{"id":"a","changes":{"x":3}}}"#, .updateNode("a", changes: JSONObject(["x": 3]))),
        (#"{"id":7,"command":"delete_nodes","args":{"ids":["a","b"]}}"#, .deleteNodes(["a", "b"])),
        (#"{"id":8,"command":"move_node","args":{"id":"a","parent":null}}"#, .moveNode("a", parent: nil, index: nil)),
        (#"{"id":9,"command":"move_node","args":{"id":"a","parent":"f","index":2}}"#, .moveNode("a", parent: "f", index: 2)),
        (#"{"id":10,"command":"select","args":{"ids":[]}}"#, .select([])),
        (#"{"id":11,"command":"undo"}"#, .undo),
        (#"{"id":12,"command":"redo"}"#, .redo),
        (#"{"id":13,"command":"new_document"}"#, .newDocument(discard: false)),
        (#"{"id":14,"command":"new_document","args":{"discard":true}}"#, .newDocument(discard: true)),
        (#"{"id":15,"command":"open_document","args":{"path":"/tmp/a.uiatlas"}}"#, .openDocument("/tmp/a.uiatlas", discard: false)),
        (#"{"id":16,"command":"save_document"}"#, .saveDocument(nil)),
        (#"{"id":17,"command":"save_document","args":{"path":"/tmp/b.uiatlas"}}"#, .saveDocument("/tmp/b.uiatlas")),
        (#"{"id":18,"command":"focus_node","args":{"id":"f"}}"#, .focusNode("f")),
        (#"{"id":19,"command":"fit_all"}"#, .fitAll),
        (#"{"id":20,"command":"zoom","args":{"scale":0.5}}"#, .zoom(0.5)),
        (#"{"id":21,"command":"node_snapshot","args":{"id":"f"}}"#, .nodeSnapshot("f", scale: 2)),
        (#"{"id":22,"command":"node_snapshot","args":{"id":"f","scale":1}}"#, .nodeSnapshot("f", scale: 1)),
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
        (#"{"id":1,"command":"select_project"}"#, "未知命令：select_project"),
        (#"{"id":1,"command":"get_node"}"#, "缺少参数：id"),
        (#"{"id":1,"command":"get_node","args":{"id":7}}"#, "参数类型错误：id"),
        (#"{"id":1,"command":"create_node","args":{}}"#, "缺少参数：node"),
        (#"{"id":1,"command":"create_node","args":{"node":[]}}"#, "参数类型错误：node"),
        (#"{"id":1,"command":"create_node","args":{"node":{},"index":-1}}"#, "参数类型错误：index"),
        (#"{"id":1,"command":"update_node","args":{"id":"a"}}"#, "缺少参数：changes"),
        (#"{"id":1,"command":"delete_nodes","args":{"ids":[]}}"#, "参数类型错误：ids"),
        (#"{"id":1,"command":"delete_nodes","args":{"ids":[1]}}"#, "参数类型错误：ids"),
        (#"{"id":1,"command":"new_document","args":{"discard":"yes"}}"#, "参数类型错误：discard"),
        (#"{"id":1,"command":"open_document","args":{}}"#, "缺少参数：path"),
        (#"{"id":1,"command":"zoom","args":{"scale":"big"}}"#, "参数类型错误：scale"),
        (#"{"id":1,"command":"zoom","args":{"scale":0}}"#, "参数类型错误：scale"),
        (#"{"id":1,"command":"zoom","args":{"scale":true}}"#, "参数类型错误：scale"),
        (#"{"id":1,"command":"node_snapshot","args":{"id":"f","scale":5}}"#, "参数类型错误：scale"),
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
    let success = try object(ControlProtocol.success(id: .int(3), result: ["file": "a", "text": "a\nb"]))
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
