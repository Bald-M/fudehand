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
    #expect(store.document.nodes.isEmpty && !store.isDirty && store.title == "Untitled")
    #expect(store.fileURL == nil)
}

@Test @MainActor func agentBuildsNestedNodesAsOneUndoStep() async throws {
    let store = makeStore()
    let created = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "type": "frame", "name": "Home", "width": 390, "height": 844, "fill": "#FFFFFF",
        "layout": ["direction": "vertical", "spacing": 12, "padding": ["top": 16, "right": 16, "bottom": 16, "left": 16], "crossAlign": "stretch"],
        "children": [["id": "nav", "type": "rectangle", "height": 56, "fill": "#F2F2F7"],
                     ["type": "text", "text": ["content": "Card"]]],
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
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "t", "type": "text", "text": ["content": "Hello"]])))
    store.updateNode("t", "Change Font Size") { $0.text?.fontSize = 30 }
    let node = try await control(store, .getNode("t"))
    #expect((node["text"] as? [String: Any])?["fontSize"] as? Double == 30)
    let updated = try await control(store, .updateNode("t", changes: JSONObject(["text": ["content": "Goodbye"], "opacity": 0.5])))
    #expect((updated["text"] as? [String: Any])?["fontSize"] as? Double == 30)
    #expect(store.editor.document.node("t")?.text?.content == "Goodbye")
    store.undo()
    #expect(store.editor.document.node("t")?.text?.content == "Hello")
    store.undo()
    #expect(store.editor.document.node("t")?.text?.fontSize == 16)
}

@Test @MainActor func invalidAgentCommandsChangeNothing() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "e", "type": "ellipse"])))
    let revision = store.editor.revision
    #expect(await failure(store, .updateNode("e", changes: JSONObject(["layout": ["spacing": 4]]))) == "Layer e: ellipse does not support layout")
    #expect(await failure(store, .createNode(parent: "e", index: nil, node: JSONObject(["type": "rectangle"]))) == "Layer e cannot contain child layers")
    #expect(await failure(store, .createNode(parent: nil, index: nil, node: JSONObject(["type": "star"])))?.contains("unknown type star") == true)
    #expect(await failure(store, .getNode("zz")) == "Layer not found: zz")
    #expect(await failure(store, .select(["zz"])) == "Layer not found: zz")
    #expect(store.editor.revision == revision)
}

@Test @MainActor func saveCloseAndReopenRoundTrips() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "f", "type": "frame", "children": [["id": "c", "type": "rectangle", "stroke": ["color": "#FF0000", "width": 2], "cornerRadius": 8]],
    ])))
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(await failure(store, .saveDocument(nil)) == "The document has never been saved; provide path")
    let saved = try await control(store, .saveDocument(url.path))
    #expect(saved["dirty"] as? Bool == false && saved["file"] as? String == url.path)
    let expected = store.editor.document
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"format\" : \"ui-atlas.design\"") && text.contains("\"version\" : 1"))

    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["type": "ellipse"])))
    #expect(await failure(store, .newDocument(discard: false)) == "The current document has unsaved changes; save it first, or pass discard: true to discard them")
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
    #expect(await failure(store, .openDocument(bad.path, discard: false)) == "File was created by a newer version of ui-atlas (format version 9); upgrade ui-atlas to open it")
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
    try store.perform("Create") { try $0.insert(DesignNode(id: "r", type: .rectangle), parent: nil, index: nil) }
    for value in [0.9, 0.8, 0.7] { store.updateNode("r", "Change Opacity", coalescing: "opacity") { $0.opacity = value } }
    store.undo()
    #expect(store.editor.document.node("r")?.opacity == 1)
    store.canvasBeginGesture("Move Layers")
    store.canvasMove(["r": Point(x: 50, y: 0)])
    #expect(store.editor.document.node("r")?.x == 50)
    #expect(store.document.node("r")?.x == 0)
    store.canvasEndGesture()
    #expect(store.document.node("r")?.x == 50)
}

@Test @MainActor func movingAParentWithItsSelectedChildMovesTheChildOnce() throws {
    let store = makeStore()
    var frame = DesignNode(id: "f", type: .frame, width: 300, height: 300)
    frame.children = [DesignNode(id: "c", type: .rectangle, x: 10, y: 10)]
    try store.perform("Create") { try $0.insert(frame, parent: nil, index: nil) }
    store.canvasNudge(["f", "c"], by: Point(x: 5, y: 0))
    #expect(store.editor.document.node("f")?.x == 5 && store.editor.document.node("c")?.x == 10)
    store.canvasBeginGesture("Move Layers")
    store.canvasMove(["f": Point(x: 25, y: 0), "c": Point(x: 35, y: 10)])
    store.canvasEndGesture()
    #expect(store.editor.document.node("f")?.x == 25 && store.editor.document.worldRect("c")?.x == 35)
}

@Test @MainActor func openingAndSavingRecordRecentDocumentsThatPersist() async throws {
    let suite = "ui-atlas-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AtlasStore(defaults: defaults)
    // The path in the entry has symlinks resolved (temporary directory /var → /private/var).
    let first = temporaryFile().resolvingSymlinksInPath(), second = temporaryFile().resolvingSymlinksInPath()
    _ = try await control(store, .saveDocument(first.path))
    _ = try await control(store, .saveDocument(second.path))
    _ = try await control(store, .openDocument(first.path, discard: false))
    #expect(store.recents.items.map(\.path) == [first.path, second.path])
    // After a restart (the same defaults) the entry is still there.
    let relaunched = AtlasStore(defaults: defaults)
    #expect(relaunched.recents.items.map(\.path) == [first.path, second.path])
    relaunched.removeRecent(first.path)
    #expect(AtlasStore(defaults: defaults).recents.items.map(\.path) == [second.path])
    relaunched.clearRecents()
    #expect(AtlasStore(defaults: defaults).recents.items.isEmpty)
}

@Test @MainActor func openingAMissingFileKeepsTheDocumentAndRecents() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    let missing = temporaryFile()
    #expect(throws: DesignError.self) { try store.open(missing) }
    #expect(store.editor.document.node("r") != nil && store.recents.items.isEmpty)
}

@Test @MainActor func templatesAreListedAndOpenAsUntitledDocuments() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-templates-\(UUID().uuidString)")
    #expect(AtlasStore.templates(in: directory).isEmpty)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(AtlasStore.templates(in: directory).isEmpty)
    let document = DesignDocument(nodes: [DesignNode(id: "f", type: .frame, x: 0, y: 0, width: 390, height: 844)])
    try document.encoded().write(to: directory.appendingPathComponent("Mobile.uiatlas"))
    try document.encoded().write(to: directory.appendingPathComponent("Desktop.uiatlas"))
    try Data().write(to: directory.appendingPathComponent("Notes.md"))
    try document.encoded().write(to: directory.appendingPathComponent("Template 10.uiatlas"))
    try document.encoded().write(to: directory.appendingPathComponent("Template 2.uiatlas"))
    let templates = AtlasStore.templates(in: directory)
    // Sorted the way Finder does: numbers compare by value.
    #expect(templates.map(\.name).filter { $0.hasPrefix("Template") } == ["Template 2", "Template 10"])
    #expect(templates.count == 4)

    let store = makeStore()
    var presented = 0
    store.presentEditor = { presented += 1 }
    try store.openTemplate(templates[0].url)
    #expect(store.fileURL == nil && store.title == "Untitled" && !store.isDirty)
    #expect(store.editor.document == document && store.recents.items.isEmpty && presented == 1)
}

@Test @MainActor func replacingTheDocumentPresentsTheEditor() async throws {
    let store = makeStore()
    var presented = 0
    store.presentEditor = { presented += 1 }
    _ = try await control(store, .newDocument(discard: false))
    let url = temporaryFile()
    _ = try await control(store, .saveDocument(url.path))
    _ = try await control(store, .openDocument(url.path, discard: false))
    #expect(presented == 2)
}

@Test @MainActor func languageDefaultsToUSEnglishAndPersists() {
    let suite = "ui-atlas-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    #expect(AtlasStore(defaults: defaults).language == .enUS)
    AppLanguage.zhHant.save(in: defaults)
    let store = AtlasStore(defaults: defaults)
    #expect(store.language == .zhHant)
    // Only the default language is assigned here: assigning sets the process-wide `L10n.language`, which tests running in parallel read.
    store.language = .enUS
    #expect(AppLanguage.saved(in: defaults) == .enUS && AtlasStore(defaults: defaults).language == .enUS)
    // Read the suite's own domain; `stringArray(forKey:)` would fall through to the system languages.
    #expect((defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String])?.first == "en-US")
}
