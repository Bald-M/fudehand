import Foundation
import Testing
import FudehandCore

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
        (#"{"id":15,"command":"open_document","args":{"path":"/tmp/a.fudehand"}}"#, .openDocument("/tmp/a.fudehand", discard: false)),
        (#"{"id":16,"command":"save_document"}"#, .saveDocument(nil)),
        (#"{"id":17,"command":"save_document","args":{"path":"/tmp/b.fudehand"}}"#, .saveDocument("/tmp/b.fudehand")),
        (#"{"id":18,"command":"focus_node","args":{"id":"f"}}"#, .focusNode("f")),
        (#"{"id":19,"command":"fit_all"}"#, .fitAll),
        (#"{"id":20,"command":"zoom","args":{"scale":0.5}}"#, .zoom(0.5)),
        (#"{"id":21,"command":"node_snapshot","args":{"id":"f"}}"#, .nodeSnapshot("f", scale: 2)),
        (#"{"id":22,"command":"node_snapshot","args":{"id":"f","scale":1}}"#, .nodeSnapshot("f", scale: 1)),
        (#"{"id":23,"command":"list_fonts"}"#, .listFonts),
        (#"{"id":24,"command":"import_font","args":{"path":"/tmp/a.ttf"}}"#, .importFont("/tmp/a.ttf")),
        (#"{"id":25,"command":"search_icons","args":{"query":"home"}}"#, .searchIcons(query: "home", library: nil, limit: 50)),
        (#"{"id":26,"command":"search_icons","args":{"query":"home","library":"material-rounded","limit":3}}"#,
         .searchIcons(query: "home", library: .materialRounded, limit: 3)),
    ]
    for (line, command) in cases {
        #expect(try parse(line).get().command == command)
    }
    #expect(try parse(#"{"id":"s","command":"fit_all"}"#).get().id == .string("s"))
    #expect(try parse(#"{"id":9,"command":"fit_all"}"#).get().id == .int(9))
    #expect(try parse(#"{"command":"fit_all"}"#).get().id == nil)
    #expect(try parse(#"{"id":1e300,"command":"fit_all"}"#).get().id == nil)
}

@Test func controlProtocolRejectsInvalidRequestsWithEnglishMessages() {
    let cases: [(String, String)] = [
        ("not json", "Request is not valid JSON"),
        ("[1,2]", "Request is not valid JSON"),
        (#"{"id":1}"#, "Missing argument: command"),
        (#"{"id":1,"command":3}"#, "Invalid argument type: command"),
        (#"{"id":1,"command":"select_project"}"#, "Unknown command: select_project"),
        (#"{"id":1,"command":"get_node"}"#, "Missing argument: id"),
        (#"{"id":1,"command":"get_node","args":{"id":7}}"#, "Invalid argument type: id"),
        (#"{"id":1,"command":"create_node","args":{}}"#, "Missing argument: node"),
        (#"{"id":1,"command":"create_node","args":{"node":[]}}"#, "Invalid argument type: node"),
        (#"{"id":1,"command":"create_node","args":{"node":{},"index":-1}}"#, "Invalid argument type: index"),
        (#"{"id":1,"command":"update_node","args":{"id":"a"}}"#, "Missing argument: changes"),
        (#"{"id":1,"command":"delete_nodes","args":{"ids":[]}}"#, "Invalid argument type: ids"),
        (#"{"id":1,"command":"delete_nodes","args":{"ids":[1]}}"#, "Invalid argument type: ids"),
        (#"{"id":1,"command":"new_document","args":{"discard":"yes"}}"#, "Invalid argument type: discard"),
        (#"{"id":1,"command":"open_document","args":{}}"#, "Missing argument: path"),
        (#"{"id":1,"command":"import_font","args":{}}"#, "Missing argument: path"),
        (#"{"id":1,"command":"zoom","args":{"scale":"big"}}"#, "Invalid argument type: scale"),
        (#"{"id":1,"command":"zoom","args":{"scale":0}}"#, "Invalid argument type: scale"),
        (#"{"id":1,"command":"zoom","args":{"scale":true}}"#, "Invalid argument type: scale"),
        (#"{"id":1,"command":"node_snapshot","args":{"id":"f","scale":5}}"#, "Invalid argument type: scale"),
        (#"{"id":1,"command":"fit_all","args":[]}"#, "Invalid argument type: args"),
        (#"{"id":1,"command":"search_icons","args":{}}"#, "Missing argument: query"),
        (#"{"id":1,"command":"search_icons","args":{"query":"x","library":"fontawesome"}}"#,
         "library must be one of sf, material-outlined, material-rounded, material-sharp, weui, lucide; got fontawesome"),
        (#"{"id":1,"command":"search_icons","args":{"query":"x","limit":0}}"#, "Invalid argument type: limit"),
        (#"{"id":1,"command":"search_icons","args":{"query":"x","limit":201}}"#, "Invalid argument type: limit"),
        (#"{"id":1,"command":"search_icons","args":{"query":"x","limit":2.5}}"#, "Invalid argument type: limit"),
    ]
    for (line, message) in cases {
        guard case .failure(let failure) = parse(line) else { Issue.record("Should be rejected: \(line)"); continue }
        #expect(failure.message == message, "\(line)")
    }
    guard case .failure(let failure) = parse(#"{"id":4,"command":"nope"}"#) else { Issue.record("Should be rejected"); return }
    #expect(failure.id == .int(4))
}

@Test func controlProtocolEncodesSingleLineResponses() throws {
    let success = try object(ControlProtocol.success(id: .int(3), result: ["file": "a", "text": "a\nb"]))
    #expect(success["id"] as? Int == 3)
    #expect(success["ok"] as? Bool == true)
    #expect((success["result"] as? [String: Any])?["text"] as? String == "a\nb")
    let failure = try object(ControlProtocol.failure(id: .string("x"), message: "Unknown command: nope"))
    #expect(failure["id"] as? String == "x")
    #expect(failure["ok"] as? Bool == false)
    #expect(failure["error"] as? String == "Unknown command: nope")
    let anonymous = try object(ControlProtocol.failure(id: nil, message: "Request is not valid JSON"))
    #expect(anonymous["id"] is NSNull)
}

@Test func controlProtocolReadsTheLeadingIDOfATruncatedRequest() {
    func leadingID(_ text: String) -> ControlID? { ControlProtocol.leadingID(Data(text.utf8)) }
    #expect(leadingID(#"{"id":12,"command":"create_node","args":{"node":{"image":{"data":"AAAA"#) == .int(12))
    #expect(leadingID(#" { "id" : "a\"b" , "command":"create_"#) == .string("a\"b"))
    #expect(leadingID(#"{"command":"create_node","id":3,"args":{"#) == nil)
    #expect(leadingID(#"{"id":1"#) == nil)
    #expect(leadingID("oops") == nil)
}
