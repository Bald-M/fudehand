import AppKit
import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

@MainActor private func makeStore() -> AtlasStore {
    AtlasStore(defaults: UserDefaults(suiteName: "ui-atlas-tests-\(UUID().uuidString)")!)
}

@MainActor private func control(_ store: AtlasStore, _ command: ControlCommand) async throws -> [String: Any] {
    try #require(try await store.handleControl(command) as? [String: Any])
}

@MainActor private func failure(_ store: AtlasStore, _ command: ControlCommand) async -> String? {
    do { _ = try await store.handleControl(command); return nil } catch { return error.localizedDescription }
}

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-\(UUID().uuidString).uiatlas")
}

@Test @MainActor func startsWithAnEmptyCleanDocument() {
    let store = makeStore()
    store.bootstrap()
    #expect(store.document.nodes.isEmpty && !store.isDirty && store.title == "未命名")
    #expect(store.fileURL == nil)
}

@Test @MainActor func agentBuildsNestedNodesAsOneUndoStep() async throws {
    let store = makeStore()
    let created = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "type": "frame", "name": "首页", "width": 390, "height": 844, "fill": "#FFFFFF",
        "layout": ["direction": "vertical", "spacing": 12, "padding": ["top": 16, "right": 16, "bottom": 16, "left": 16], "crossAlign": "stretch"],
        "children": [["id": "nav", "type": "rectangle", "height": 56, "fill": "#F2F2F7"],
                     ["type": "text", "text": ["content": "卡片"]]],
    ])))
    let frameID = try #require(created["id"] as? String)
    #expect((created["ids"] as? [String])?.count == 3)
    let nav = try #require(store.editor.document.node("nav"))
    #expect(nav.frame == Rect(x: 16, y: 16, width: 358, height: 56))
    #expect(store.document.node(frameID) != nil && store.isDirty)
    _ = try await control(store, .undo)
    #expect(store.editor.document.nodes.isEmpty)
    _ = try await control(store, .redo)
    #expect(store.editor.document.node("nav") != nil)
}

@Test @MainActor func agentSeesManualEditsAndUpdatesMergeFields() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "t", "type": "text", "text": ["content": "你好"]])))
    store.updateNode("t", "修改字号") { $0.text?.fontSize = 30 }
    let node = try await control(store, .getNode("t"))
    #expect((node["text"] as? [String: Any])?["fontSize"] as? Double == 30)
    let updated = try await control(store, .updateNode("t", changes: JSONObject(["text": ["content": "再见"], "opacity": 0.5])))
    #expect((updated["text"] as? [String: Any])?["fontSize"] as? Double == 30)
    #expect(store.editor.document.node("t")?.text?.content == "再见")
    store.undo()
    #expect(store.editor.document.node("t")?.text?.content == "你好")
    store.undo()
    #expect(store.editor.document.node("t")?.text?.fontSize == 16)
}

@Test @MainActor func invalidAgentCommandsChangeNothing() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "e", "type": "ellipse"])))
    let revision = store.editor.revision
    #expect(await failure(store, .updateNode("e", changes: JSONObject(["layout": ["spacing": 4]]))) == "图层 e：ellipse 不支持 layout")
    #expect(await failure(store, .createNode(parent: "e", index: nil, node: JSONObject(["type": "rectangle"]))) == "图层 e 不能包含子图层")
    #expect(await failure(store, .createNode(parent: nil, index: nil, node: JSONObject(["type": "star"])))?.contains("未知类型 star") == true)
    #expect(await failure(store, .getNode("zz")) == "找不到图层：zz")
    #expect(await failure(store, .select(["zz"])) == "找不到图层：zz")
    #expect(store.editor.revision == revision)
}

@Test @MainActor func saveCloseAndReopenRoundTrips() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "f", "type": "frame", "children": [["id": "c", "type": "rectangle", "stroke": ["color": "#FF0000", "width": 2], "cornerRadius": 8]],
    ])))
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(await failure(store, .saveDocument(nil)) == "文档还没有保存过，请提供 path")
    let saved = try await control(store, .saveDocument(url.path))
    #expect(saved["dirty"] as? Bool == false && saved["file"] as? String == url.path)
    let expected = store.editor.document
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"format\" : \"ui-atlas.design\"") && text.contains("\"version\" : 1"))

    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["type": "ellipse"])))
    #expect(await failure(store, .newDocument(discard: false)) == "当前文档有未保存的修改；先保存，或传 discard: true 放弃修改")
    _ = try await control(store, .newDocument(discard: true))
    #expect(store.editor.document.nodes.isEmpty && !store.canUndo)

    let reopened = makeStore()
    _ = try await control(reopened, .openDocument(url.path, discard: false))
    #expect(reopened.editor.document == expected && !reopened.isDirty && reopened.title == url.deletingPathExtension().lastPathComponent)
}

@Test @MainActor func openingABadFileKeepsTheCurrentDocument() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    _ = try await control(store, .saveDocument(temporaryFile().path))
    let bad = temporaryFile()
    try Data(#"{"format":"ui-atlas.design","version":9,"nodes":[]}"#.utf8).write(to: bad)
    defer { try? FileManager.default.removeItem(at: bad) }
    #expect(await failure(store, .openDocument(bad.path, discard: false)) == "文件由更新版本的 ui-atlas 创建（格式版本 9），请升级后再打开")
    #expect(store.editor.document.node("r") != nil)
}

@Test @MainActor func snapshotReturnsPNGOfTheNode() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "f", "type": "frame", "width": 120, "height": 60, "fill": "#336699"])))
    let shot = try await control(store, .nodeSnapshot("f", scale: 1))
    let data = try #require(Data(base64Encoded: shot["data"] as? String ?? ""))
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(shot["mimeType"] as? String == "image/png")
    #expect(image.pixelsWide == 120 && image.pixelsHigh == 60)
}

@Test @MainActor func stateDescribesDocument() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "f", "type": "frame", "children": [["id": "c", "type": "rectangle"]]])))
    _ = try await control(store, .select(["c"]))
    let state = try await control(store, .getState)
    #expect(state["selection"] as? [String] == ["c"])
    #expect(state["nodeCount"] as? Int == 2)
    #expect(state["canUndo"] as? Bool == true)
    #expect((state["nodes"] as? [[String: Any]])?.first?["children"] as? Int == 1)
    let deleted = try await control(store, .deleteNodes(["f"]))
    #expect(deleted["deleted"] as? [String] == ["f"])
    #expect(store.selection.isEmpty)
}

@Test @MainActor func manualEditsCoalesceAndPanelsSkipLiveGestureFrames() throws {
    let store = makeStore()
    try store.perform("新建") { try $0.insert(DesignNode(id: "r", type: .rectangle), parent: nil, index: nil) }
    for value in [0.9, 0.8, 0.7] { store.updateNode("r", "修改透明度", coalescing: "opacity") { $0.opacity = value } }
    store.undo()
    #expect(store.editor.document.node("r")?.opacity == 1)
    store.canvasBeginGesture("移动图层")
    store.canvasMove(["r": Point(x: 50, y: 0)])
    #expect(store.editor.document.node("r")?.x == 50)
    #expect(store.document.node("r")?.x == 0)
    store.canvasEndGesture()
    #expect(store.document.node("r")?.x == 50)
}
