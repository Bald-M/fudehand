import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

@MainActor private func makeStore() -> FudehandStore {
    FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!)
}

@MainActor private func control(_ store: FudehandStore, _ command: ControlCommand) async throws -> [String: Any] {
    try #require(try await store.handleControl(command) as? [String: Any])
}

@MainActor private func failure(_ store: FudehandStore, _ command: ControlCommand) async -> String? {
    do { _ = try await store.handleControl(command); return nil } catch { return error.localizedDescription }
}

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-\(UUID().uuidString).fudehand")
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

@Test @MainActor func agentAndPanelEditLayoutGuidesAsOneUndoStepEach() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "f", "type": "frame"])))
    // The panel's + adds a grid; the Agent then sees it and replaces the list.
    store.updateNode("f", "Add Layout Guide") { $0.layoutGuides.append(LayoutGuide(type: .grid)) }
    let node = try await control(store, .getNode("f"))
    #expect((node["layoutGuides"] as? [[String: Any]])?.first?["type"] as? String == "grid")
    _ = try await control(store, .updateNode("f", changes: JSONObject(["layoutGuides": [["type": "columns", "count": 12], ["type": "rows", "visible": false]]])))
    #expect(store.editor.document.node("f")?.layoutGuides.map(\.type) == [.columns, .rows])
    store.updateNode("f", "Show Layout Guide") { $0.layoutGuides[1].visible = true }
    store.updateNode("f", "Remove Layout Guide") { $0.layoutGuides.remove(at: 0) }
    #expect(store.editor.document.node("f")?.layoutGuides.map(\.type) == [.rows])
    store.undo()
    #expect(store.editor.document.node("f")?.layoutGuides.map(\.type) == [.columns, .rows])
    store.undo()
    #expect(store.editor.document.node("f")?.layoutGuides[1].visible == false)
    store.undo()
    #expect(store.editor.document.node("f")?.layoutGuides.map(\.type) == [.grid])
    store.undo()
    #expect(store.editor.document.node("f")?.layoutGuides.isEmpty == true)
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
    #expect(text.contains("\"format\" : \"fudehand.design\"") && text.contains("\"version\" : \(DesignDocument.formatVersion)"))

    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["type": "ellipse"])))
    #expect(await failure(store, .newDocument(discard: false)) == "The current document has unsaved changes; save it first, or pass discard: true to discard them")
    _ = try await control(store, .newDocument(discard: true))
    #expect(store.editor.document.nodes.isEmpty && !store.canUndo)

    let reopened = makeStore()
    _ = try await control(reopened, .openDocument(url.path, discard: false))
    #expect(reopened.editor.document == expected && !reopened.isDirty && reopened.title == url.deletingPathExtension().lastPathComponent)
}

/// The file is read in the background (#248): an edit made meanwhile is not dropped unless discarding is allowed again.
@Test @MainActor func anEditWhileAFileIsReadIsKeptUnlessDiscarded() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try DesignDocument(nodes: [DesignNode(id: "opened", type: .rectangle)]).encoded().write(to: url)
    for allowed in [false, true] {
        let store = makeStore()
        var asked = 0
        let open = Task { try await store.open(url) { asked += 1; return allowed } }
        // The open starts and waits for the read; the edit lands before it resumes.
        await Task.yield()
        _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "edit", "type": "ellipse"])))
        try await open.value
        #expect(asked == 1)
        #expect((store.editor.document.node("edit") != nil) == !allowed && (store.editor.document.node("opened") != nil) == allowed)
    }
}

/// When a second file is opened while the first is still being read, the second is the one that stays open.
@Test @MainActor func theLastFileOpenedWins() async throws {
    let first = temporaryFile(), second = temporaryFile()
    defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
    // The first file is large, so it is still being read when the small second one has been read.
    var large = DesignNode(id: "first", type: .frame, width: 100, height: 100)
    large.children = (0..<20_000).map { DesignNode(id: "r\($0)", type: .rectangle, width: 1, height: 1) }
    try DesignDocument(nodes: [large]).encoded().write(to: first)
    try DesignDocument(nodes: [DesignNode(id: "second", type: .rectangle)]).encoded().write(to: second)
    let store = makeStore()
    let a = Task { try await store.open(first) { true } }
    await Task.yield()
    let b = Task { try await store.open(second) { true } }
    await Task.yield()
    try await a.value
    try await b.value
    #expect(store.editor.document.node("second") != nil && store.fileURL == second)
}

@Test @MainActor func openingABadFileKeepsTheCurrentDocument() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    _ = try await control(store, .saveDocument(temporaryFile().path))
    let bad = temporaryFile()
    try Data(#"{"format":"fudehand.design","version":11,"nodes":[]}"#.utf8).write(to: bad)
    defer { try? FileManager.default.removeItem(at: bad) }
    #expect(await failure(store, .openDocument(bad.path, discard: false)) == "File was created by a newer version of Fudehand (format version 11); upgrade Fudehand to open it")
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

@Test @MainActor func movingLayersUnderDifferentParentsInOneDragMovesEach() throws {
    let store = makeStore()
    var frame = DesignNode(id: "f", type: .frame, x: 100, y: 50, width: 300, height: 300)
    frame.children = [DesignNode(id: "c", type: .rectangle, x: 10, y: 10), DesignNode(id: "d", type: .rectangle, x: 150, y: 10)]
    try store.perform("Create") { document in
        try document.insert(frame, parent: nil, index: nil)
        try document.insert(DesignNode(id: "t", type: .rectangle, x: 600, y: 0), parent: nil, index: nil)
    }
    store.canvasBeginGesture("Move Layers")
    for step in [1.0, 2.0] {
        store.canvasMove(["c": Point(x: 110 + 20 * step, y: 60), "t": Point(x: 600, y: 30 * step)])
    }
    store.canvasEndGesture()
    let document = store.editor.document
    #expect(document.worldRect("c") == Rect(x: 150, y: 60, width: 100, height: 100) && document.node("c")?.x == 50)
    #expect(document.node("t")?.frame == Rect(x: 600, y: 60, width: 100, height: 100))
    #expect(document.node("d")?.x == 150 && document.node("f")?.x == 100)
    store.undo()
    #expect(store.editor.document.node("c")?.x == 10 && store.editor.document.node("t")?.y == 0)
}

@Test @MainActor func openingAndSavingRecordRecentDocumentsThatPersist() async throws {
    let suite = "fudehand-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = FudehandStore(defaults: defaults)
    // The path in the entry has symlinks resolved (temporary directory /var → /private/var).
    let first = temporaryFile().resolvingSymlinksInPath(), second = temporaryFile().resolvingSymlinksInPath()
    _ = try await control(store, .saveDocument(first.path))
    _ = try await control(store, .saveDocument(second.path))
    _ = try await control(store, .openDocument(first.path, discard: false))
    #expect(store.recents.items.map(\.path) == [first.path, second.path])
    // After a restart (the same defaults) the entry is still there.
    let relaunched = FudehandStore(defaults: defaults)
    #expect(relaunched.recents.items.map(\.path) == [first.path, second.path])
    relaunched.removeRecent(first.path)
    #expect(FudehandStore(defaults: defaults).recents.items.map(\.path) == [second.path])
    relaunched.clearRecents()
    #expect(FudehandStore(defaults: defaults).recents.items.isEmpty)
}

@Test @MainActor func openingAMissingFileKeepsTheDocumentAndRecents() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    let missing = temporaryFile()
    await #expect(throws: DesignError.self) { try await store.open(missing) { true } }
    #expect(store.editor.document.node("r") != nil && store.recents.items.isEmpty)
}

@Test @MainActor func templatesAreListedAndOpenAsUntitledDocuments() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-templates-\(UUID().uuidString)")
    #expect(FudehandStore.templates(in: directory).isEmpty)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(FudehandStore.templates(in: directory).isEmpty)
    let document = DesignDocument(nodes: [DesignNode(id: "f", type: .frame, x: 0, y: 0, width: 390, height: 844)])
    try document.encoded().write(to: directory.appendingPathComponent("Mobile.fudehand"))
    try document.encoded().write(to: directory.appendingPathComponent("Desktop.fudehand"))
    try Data().write(to: directory.appendingPathComponent("Notes.md"))
    try document.encoded().write(to: directory.appendingPathComponent("Template 10.fudehand"))
    try document.encoded().write(to: directory.appendingPathComponent("Template 2.fudehand"))
    let templates = FudehandStore.templates(in: directory)
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

/// The App opens the editor window in a later main-thread turn (#252); an Agent command that enters the editor answers only
/// after that, so the Agent's next command finds the window and its canvas.
@Test @MainActor func agentCommandsThatEnterTheEditorAnswerAfterItOpens() async throws {
    let store = makeStore()
    var opened = 0
    store.presentEditor = { DispatchQueue.main.async { opened += 1 } }
    _ = try await control(store, .newDocument(discard: false))
    #expect(opened == 1)
    let url = temporaryFile()
    _ = try await control(store, .saveDocument(url.path))
    _ = try await control(store, .openDocument(url.path, discard: false))
    #expect(opened == 2)
    _ = try await control(store, .newDocument(discard: true))
    _ = try await control(store, .openRecent(url.path, discard: false))
    #expect(opened == 4)
}

@Test @MainActor func languageDefaultsToUSEnglishAndPersists() {
    let suite = "fudehand-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    #expect(FudehandStore(defaults: defaults).language == .enUS)
    AppLanguage.zhHant.save(in: defaults)
    let store = FudehandStore(defaults: defaults)
    #expect(store.language == .zhHant)
    // Only the default language is assigned here: assigning sets the process-wide `L10n.language`, which tests running in parallel read.
    store.language = .enUS
    #expect(AppLanguage.saved(in: defaults) == .enUS && FudehandStore(defaults: defaults).language == .enUS)
    // Read the suite's own domain; `stringArray(forKey:)` would fall through to the system languages.
    #expect((defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String])?.first == "en-US")
}

@Test @MainActor func returningToTheSavedContentClearsTheEditedState() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "box", "type": "rectangle", "x": 10, "y": 20])))
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await control(store, .saveDocument(url.path))
    #expect(!store.isDirty)

    // Dragging a layer away and back to where it started leaves the content as saved.
    store.canvasBeginGesture("Move")
    store.canvasMove(["box": Point(x: 50, y: 60)])
    #expect(store.isDirty)
    store.canvasMove(["box": Point(x: 10, y: 20)])
    store.canvasEndGesture()
    #expect(!store.isDirty)

    // Undoing an edit back to the saved content.
    _ = try await control(store, .updateNode("box", changes: JSONObject(["x": 99])))
    #expect(store.isDirty)
    _ = try await control(store, .undo)
    #expect(!store.isDirty)
    _ = try await control(store, .redo)
    #expect(store.isDirty)
}

@Test @MainActor func editedStateFollowsUndoAndRedoAroundTheSavePoint() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "box", "type": "rectangle", "x": 10, "y": 20])))
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await control(store, .saveDocument(url.path))

    // Undoing past the save point leaves content that differs from the file.
    _ = try await control(store, .undo)
    #expect(try await control(store, .getState)["dirty"] as? Bool == true)
    _ = try await control(store, .redo)
    #expect(try await control(store, .getState)["dirty"] as? Bool == false)

    // A drag is still one undo step, and undoing it returns to the save point.
    store.canvasBeginGesture("Move")
    store.canvasMove(["box": Point(x: 30, y: 40)])
    store.canvasMove(["box": Point(x: 50, y: 60)])
    store.canvasEndGesture()
    #expect(try await control(store, .getState)["dirty"] as? Bool == true)
    _ = try await control(store, .undo)
    #expect(store.editor.document.node("box")?.frame.x == 10 && store.canRedo)
    #expect(try await control(store, .getState)["dirty"] as? Bool == false)
    _ = try await control(store, .redo)
    #expect(store.editor.document.node("box")?.frame.x == 50 && store.isDirty)
}

@Test @MainActor func conversationsBelongToTheDocumentTheyWereHeldAbout() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-chats-\(UUID().uuidString)")
    let a = temporaryFile(), b = temporaryFile()
    defer { for url in [root, a, b] { try? FileManager.default.removeItem(at: url) } }
    let defaults = UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!
    let store = FudehandStore(defaults: defaults, chatRoot: root)
    // Without a source directory the message fails at once; the conversation is saved all the same.
    store.chat.send("About A", root: nil, runtime: nil)
    let inA = store.chat.conversationID

    // The first save takes the untitled document's conversations to the file.
    try store.write(to: a)
    #expect(store.chat.tabs.map(\.id) == [inA])
    #expect(!(try String(contentsOf: a, encoding: .utf8)).contains("About A"))

    // Another document shows none of them, and what is said in a document that is never saved is dropped.
    store.replace(DesignDocument(), url: nil)
    #expect(store.chat.transcript.entries.isEmpty)
    #expect(store.chat.conversations.isEmpty)
    store.chat.send("Never saved", root: nil, runtime: nil)
    try await store.open(a) { true }
    #expect(store.chat.tabs.map(\.id) == [inA])
    #expect(store.chat.conversations.map(\.title) == ["About A"])
    store.replace(DesignDocument(), url: nil)
    #expect(store.chat.conversations.isEmpty)

    // Save As copies the conversations; the original file keeps its own.
    try await store.open(a) { true }
    try store.write(to: b)
    #expect(store.chat.conversations.map(\.title) == ["About A"])
    try await store.open(a) { true }
    #expect(store.chat.tabs.map(\.id) == [inA])

    // On a case-insensitive volume the same file under another spelling of its name has the same conversations.
    let respelled = a.deletingLastPathComponent().appendingPathComponent(a.lastPathComponent.uppercased())
    if FileManager.default.fileExists(atPath: respelled.path) {
        try await store.open(respelled) { true }
        #expect(store.chat.tabs.map(\.id) == [inA])
    }

    // After a relaunch the untitled document starts empty, and opening the file restores its conversation.
    store.replace(DesignDocument(), url: nil)
    store.chat.send("Lost at quit", root: nil, runtime: nil)
    let relaunched = FudehandStore(defaults: defaults, chatRoot: root)
    #expect(relaunched.chat.transcript.entries.isEmpty)
    #expect(relaunched.chat.conversations.isEmpty)
    try await relaunched.open(a) { true }
    #expect(relaunched.chat.tabs.map(\.id) == [inA])
    #expect(relaunched.chat.transcript.entries.first?.text == "About A")
}

@Test @MainActor func agentSetsInteractionsOnlyToTopLevelFrames() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "home", "type": "frame", "children": [["id": "button", "type": "rectangle"], ["id": "inner", "type": "frame"]],
    ])))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "detail", "type": "frame"])))
    let updated = try await control(store, .updateNode("button", changes: JSONObject([
        "interaction": ["action": "navigate", "destination": "detail", "transition": ["type": "dissolve"]],
    ])))
    let interaction = try #require(updated["interaction"] as? [String: Any])
    #expect(interaction["destination"] as? String == "detail")
    #expect(store.editor.document.node("button")?.interaction == .navigate(destination: "detail", transition: PrototypeTransition(type: .dissolve)))
    #expect(await failure(store, .updateNode("button", changes: JSONObject(["interaction": ["action": "navigate", "destination": "inner"]])))
            == "Layer button: interaction.destination inner is not a top-level frame")
    #expect(await failure(store, .createNode(parent: "home", index: nil, node: JSONObject([
        "type": "rectangle", "interaction": ["action": "navigate", "destination": "missing"],
    ])))?.hasSuffix("interaction.destination missing is not a top-level frame") == true)
    // Undo takes the interaction away like any other edit.
    store.undo()
    #expect(store.editor.document.node("button")?.interaction == nil)
}

@Test @MainActor func agentSetsInScreenInteractions() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "home", "type": "frame", "scroll": "vertical",
        "children": [["id": "bar", "type": "rectangle", "fixedOnScroll": true], ["id": "tab", "type": "rectangle"], ["id": "panel", "type": "rectangle"]],
    ])))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "menu", "type": "frame"])))
    let updated = try await control(store, .updateNode("tab", changes: JSONObject([
        "states": ["pressed": ["opacity": 0.5]],
        "interaction": ["action": "open-overlay", "destination": "menu", "position": "bottom", "background": "#00000066"],
    ])))
    #expect((updated["states"] as? [String: Any])?["pressed"] != nil)
    let tab = try #require(store.editor.document.node("tab"))
    #expect(tab.states == LayerStates(pressed: LayerStyle(opacity: 0.5)))
    let scrim = try DesignColor(hex: "#00000066")
    #expect(tab.interaction == .openOverlay(destination: "menu", overlay: OverlaySettings(position: .bottom, background: scrim), transition: PrototypeTransition()))
    #expect(store.editor.document.node("home")?.scroll == .vertical && store.editor.document.node("bar")?.fixedOnScroll == true)
    _ = try await control(store, .updateNode("tab", changes: JSONObject(["interaction": ["action": "toggle-visibility", "targets": ["panel"]]])))
    #expect(await failure(store, .updateNode("tab", changes: JSONObject(["interaction": ["action": "toggle-visibility", "targets": ["nope"]]])))
            == "Layer tab: interaction.targets includes nope, which is not a layer")
    #expect(await failure(store, .updateNode("tab", changes: JSONObject(["scroll": "vertical"]))) == "Layer tab: rectangle does not support scroll")
}

@Test @MainActor func agentAndPanelSetTheSameAnimationsAndSequences() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "screen", "type": "frame", "children": [["id": "spinner", "type": "ellipse"], ["id": "count", "type": "text", "text": ["content": "60"]]],
    ])))
    let updated = try await control(store, .updateNode("spinner", changes: JSONObject(["animation": ["type": "spin", "duration": 0.8]])))
    #expect((updated["animation"] as? [String: Any])?["repeat"] as? String == "infinite")
    var spin = LayerAnimation(type: .spin)
    spin.duration = 0.8
    #expect(store.editor.document.node("spinner")?.animation == spin)
    _ = try await control(store, .updateNode("count", changes: JSONObject(["text": ["sequence": ["items": ["3", "2", "1"], "loop": true]]])))
    #expect(store.editor.document.node("count")?.text?.sequence == TextSequence(items: ["3", "2", "1"], loop: true))
    // The text itself, which the canvas and snapshots show, is unchanged.
    #expect(store.editor.document.node("count")?.text?.content == "60")

    // The properties panel goes through the same edit path and the same undo history.
    store.updateNode("spinner", "Change Animation") { $0.animation = LayerAnimation(type: .pulse) }
    #expect(store.editor.document.node("spinner")?.animation == LayerAnimation(type: .pulse))
    store.undo()
    #expect(store.editor.document.node("spinner")?.animation == spin)
    store.undo()
    #expect(store.editor.document.node("count")?.text?.sequence == nil)
    #expect(await failure(store, .updateNode("spinner", changes: JSONObject(["animation": ["type": "spin", "from": "left"]])))
            == "Layer spinner: unsupported field animation.from")
}

@Test @MainActor func playbackStartsFromTheSelectedFrame() async throws {
    let store = makeStore()
    #expect(store.prototypeStart == nil)
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "a", "type": "frame", "children": [["id": "c", "type": "rectangle"]]])))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "b", "type": "frame"])))
    #expect(store.prototypeStart == "a")
    store.setSelection(["b"])
    #expect(store.prototypeStart == "b")
    store.setSelection(["c"])
    #expect(store.prototypeStart == "a")
}

@Test @MainActor func agentPlaysAndClosesThePrototypeWindowLikeTheUI() async throws {
    let store = makeStore()
    var presented = 0, dismissed = 0
    store.presentPrototype = { presented += 1 }
    store.dismissPrototype = { dismissed += 1 }
    #expect(await failure(store, .playPrototype(frame: nil)) == "The document has no top-level frame to play; add a frame first")
    store.playPrototype()
    #expect(store.alert == L("Add a frame to play the prototype.") && presented == 0)
    #expect(await failure(store, .closePrototype) == "The prototype window is not open")
    let closed = try await control(store, .getPrototypePlayback)
    #expect(closed["open"] as? Bool == false && closed["frame"] is NSNull)

    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "a", "type": "frame", "name": "Home",
                                                                                          "children": [["id": "c", "type": "rectangle"]]])))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "b", "type": "frame", "name": "Detail"])))
    // Without a frame it starts where Play Prototype starts: the frame holding the selection.
    store.setSelection(["b"])
    let played = try await control(store, .playPrototype(frame: nil))
    #expect(played["open"] as? Bool == true && played["frame"] as? String == "b" && played["name"] as? String == "Detail")
    #expect(presented == 1 && store.prototypeRequest?.start == "b")
    let firstToken = try #require(store.prototypeRequest?.token)
    store.playPrototype()
    #expect(store.prototypeRequest == PrototypeRequest(start: "b", token: firstToken + 1) && presented == 2)

    // From a given top-level frame; layers inside a frame and missing layers are refused without opening anything.
    #expect(try await control(store, .playPrototype(frame: "a"))["frame"] as? String == "a")
    #expect(await failure(store, .playPrototype(frame: "c")) == "Layer c is not a top-level frame")
    #expect(await failure(store, .playPrototype(frame: "zz")) == "Layer not found: zz")
    #expect(store.prototypeRequest?.start == "a" && presented == 3)

    // The stage reports where playback moved, redrawing only the prototype window; a deleted frame reads as null while the window stays open.
    var storeChanges = 0, shownChanges = 0
    let observers = [store.objectWillChange.sink { storeChanges += 1 }, store.prototypeShown.objectWillChange.sink { shownChanges += 1 }]
    store.prototypeMoved(to: "b")
    #expect(storeChanges == 0 && shownChanges == 1)
    _ = observers
    #expect(try await control(store, .getPrototypePlayback)["frame"] as? String == "b")
    _ = try await control(store, .deleteNodes(["b"]))
    let deleted = try await control(store, .getPrototypePlayback)
    #expect(deleted["open"] as? Bool == true && deleted["frame"] is NSNull)

    let after = try await control(store, .closePrototype)
    #expect(after["open"] as? Bool == false && after["frame"] is NSNull && dismissed == 1)
}

/// Selecting notifies only the views that observe the selection; the workspace, which observes the store, is not recomputed
/// (#142).
@Test @MainActor func selectingNotifiesTheSelectionWithoutInvalidatingTheStore() {
    let store = makeStore()
    store.replace(DesignDocument(nodes: [DesignNode(id: "a", type: .rectangle), DesignNode(id: "b", type: .rectangle)]), url: nil)
    var storeChanges = 0, selectionChanges = 0
    let observers = [store.objectWillChange.sink { storeChanges += 1 },
                     store.layerSelection.objectWillChange.sink { selectionChanges += 1 }]
    store.setSelection(["a"])
    store.canvasSelect(["a", "b"])
    store.setSelection(["a", "b"])
    #expect(store.selection == ["a", "b"] && store.layerSelection.ids == ["a", "b"])
    #expect(selectionChanges == 2)
    #expect(storeChanges == 0)
    _ = observers
}

/// An edit notifies the views that show the document, but not the store's observers (the editor window and its toolbar), and
/// notifies the layers panel only when its rows change (#228).
@Test @MainActor func editsNotifyOnlyTheViewsShowingWhatChanged() throws {
    let store = makeStore()
    store.replace(DesignDocument(nodes: [DesignNode(id: "a", type: .rectangle, name: "A"), DesignNode(id: "b", type: .rectangle, name: "B")]),
                  url: nil)
    #expect(store.layerOutline.rows.map(\.name) == ["B", "A"] && store.layerOutline.count == 2)
    // The first edit marks the document edited, which the window title shows.
    var storeChanges = 0, documentChanges = 0, outlineChanges = 0
    let observers = [store.objectWillChange.sink { storeChanges += 1 },
                     store.displayed.objectWillChange.sink { documentChanges += 1 },
                     store.layerOutline.objectWillChange.sink { outlineChanges += 1 }]
    store.canvasNudge(["a"], by: Point(x: 1, y: 0))
    #expect(store.isDirty && storeChanges == 1 && documentChanges == 1 && outlineChanges == 0)

    store.canvasNudge(["a"], by: Point(x: 1, y: 0))
    store.undo()
    #expect(store.document.node("a")?.x == 1)
    #expect(storeChanges == 1 && documentChanges == 3 && outlineChanges == 0)

    store.updateNode("b", "Rename Layer") { $0.name = "Second" }
    #expect(store.layerOutline.rows.map(\.name) == ["Second", "A"] && outlineChanges == 1)
    store.setCollapsed("b", true)
    #expect(store.layerOutline.rows.first?.collapsed == true && outlineChanges == 2)
    store.undo()
    store.undo()
    #expect(!store.isDirty && storeChanges >= 2)
    _ = observers
}

// MARK: Icon layers

@Test @MainActor func createIconLayer() async throws {
    let store = makeStore()
    let created = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "i", "type": "icon", "icon": ["name": "lucide/house"]])))
    let node = try #require(created["node"] as? [String: Any])
    #expect(node["width"] as? Double == 24 && node["height"] as? Double == 24)
    #expect(node["icon"] as? [String: String] == ["name": "lucide/house", "color": "#000000"])
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "s", "type": "icon", "width": 40, "icon": ["name": "sf/house.fill"]])))
    #expect(store.editor.document.node("s")?.width == 40 && store.editor.document.node("s")?.height == 24)
}

@Test @MainActor func unknownIconIsRejectedWithSuggestions() async throws {
    let store = makeStore()
    let message = await failure(store, .createNode(parent: nil, index: nil, node: JSONObject(["type": "icon", "icon": ["name": "lucide/hous"]])))
    #expect(message?.hasPrefix("Unknown icon lucide/hous; similar: lucide/house") == true)
    #expect(store.editor.document.nodes.isEmpty && !store.canUndo)
    #expect(await failure(store, .createNode(parent: nil, index: nil, node: JSONObject(["type": "icon", "icon": ["name": "weui/zzzzzzzzzzzzzzzzzzzz"]])))?
        .hasPrefix("Unknown icon weui/zzzzzzzzzzzzzzzzzzzz; similar: weui/") == true)
}

@Test @MainActor func unknownNestedIconCreatesNothing() async throws {
    let store = makeStore()
    let message = await failure(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "f", "type": "frame", "children": [["type": "icon", "icon": ["name": "lucide/house"]],
                                                  ["type": "group", "children": [["type": "icon", "icon": ["name": "material-sharp/nope-nope"]]]]],
    ])))
    #expect(message?.hasPrefix("Unknown icon material-sharp/nope-nope") == true)
    #expect(store.editor.document.nodes.isEmpty)
}

@Test @MainActor func updateToUnknownIconIsRejected() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "i", "type": "icon", "icon": ["name": "lucide/house"]])))
    #expect(await failure(store, .updateNode("i", changes: JSONObject(["icon": ["name": "sf/not.a.real.symbol"]])))?
        .hasPrefix("Unknown icon sf/not.a.real.symbol") == true)
    #expect(store.editor.document.node("i")?.icon?.name == "lucide/house")
    _ = try await control(store, .updateNode("i", changes: JSONObject(["icon": ["name": "material-outlined/home", "color": "#FF0000"]])))
    let red = try DesignColor(hex: "#FF0000")
    #expect(store.editor.document.node("i")?.icon == DesignIcon(name: "material-outlined/home", color: red))
}

@Test @MainActor func updatingOtherFieldsOfUnknownIconIsAllowed() async throws {
    let store = makeStore()
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    var node = DesignNode(id: "i", type: .icon, width: 24, height: 24)
    node.icon = DesignIcon(name: "sf/not.a.real.symbol")
    try DesignDocument(nodes: [node]).encoded().write(to: url)
    try await store.open(url) { true }
    _ = try await control(store, .updateNode("i", changes: JSONObject(["x": 12, "icon": ["color": "#336699"]])))
    #expect(store.editor.document.node("i")?.x == 12)
    #expect(store.editor.document.node("i")?.icon?.name == "sf/not.a.real.symbol")
}

@Test @MainActor func searchIconsReturnsNames() async throws {
    let store = makeStore()
    let result = try await control(store, .searchIcons(query: "house", library: .lucide, limit: 3))
    let icons = try #require(result["icons"] as? [String])
    #expect(icons.count == 3 && icons.first == "lucide/house")
    let symbols = try await control(store, .searchIcons(query: "house.fill", library: .sf, limit: 50))
    #expect((symbols["icons"] as? [String])?.first == "sf/house.fill")
}

@Test @MainActor func iconSnapshotViaControl() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "f", "type": "frame", "width": 48, "height": 48, "fill": "#FFFFFF",
        "children": [["type": "icon", "width": 48, "height": 48, "icon": ["name": "material-outlined/home", "color": "#FF0000"]]],
    ])))
    let shot = try await control(store, .nodeSnapshot("f", scale: 1))
    let encoded = try #require(shot["data"] as? String)
    let png = try #require(Data(base64Encoded: encoded))
    let image = try #require(NSBitmapImageRep(data: png))
    let bytes = try #require(image.bitmapData)
    // The roof's peak at the top center is red.
    #expect(bytes[8 * image.bytesPerRow + 24 * image.samplesPerPixel] == 255 && bytes[8 * image.bytesPerRow + 24 * image.samplesPerPixel + 1] == 0)
}

@Test @MainActor func iconColorChangeIsOneUndoStep() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "i", "type": "icon", "icon": ["name": "lucide/house"]])))
    let red = try DesignColor(hex: "#FF0000"), blue = try DesignColor(hex: "#0000FF")
    // The properties panel's color well sends a stream of changes while dragging; they coalesce into one step.
    store.updateNode("i", "Change Icon Color", coalescing: "icon.color") { $0.icon?.color = red }
    store.updateNode("i", "Change Icon Color", coalescing: "icon.color") { $0.icon?.color = blue }
    #expect(store.editor.document.node("i")?.icon?.color == blue)
    store.undo()
    #expect(store.editor.document.node("i")?.icon?.color == .black)
}

/// A frame (red fill) with a red rectangle, a text layer in red, and a blue icon; a red rectangle outside it.
@MainActor private func selectionColorStore() async throws -> FudehandStore {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "f", "type": "frame", "fill": "#FF0000",
        "children": [["id": "r", "type": "rectangle", "fill": "#FF0000", "stroke": ["color": "#0000FF", "width": 1]],
                     ["id": "t", "type": "text", "text": ["content": "Hi", "color": "#FF0000"]],
                     ["id": "i", "type": "icon", "icon": ["name": "lucide/house", "color": "#0000FF"]]],
    ])))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "o", "type": "rectangle", "fill": "#FF0000"])))
    return store
}

private func colorList(_ result: [String: Any]) -> [String] {
    (result["colors"] as? [[String: Any]] ?? []).map { "\($0["color"] as? String ?? "?")×\($0["count"] as? Int ?? -1)" }
}

@Test @MainActor func agentListsSelectionColorsOfTheSelectionOrOfNamedLayers() async throws {
    let store = try await selectionColorStore()
    #expect(await failure(store, .listColors(ids: nil)) == "Nothing is selected; select layers or pass ids")
    #expect(await failure(store, .listColors(ids: ["missing"])) == "Layer not found: missing")
    store.setSelection(["f"])
    let selected = try await control(store, .listColors(ids: nil))
    #expect(selected["ids"] as? [String] == ["f"] && colorList(selected) == ["#FF0000×3", "#0000FF×2"])
    #expect(colorList(try await control(store, .listColors(ids: ["t", "o"]))) == ["#FF0000×2"])
}

@Test @MainActor func agentReplacesASelectionColorLikeThePanelAsOneUndoStep() async throws {
    let store = try await selectionColorStore()
    let red = try DesignColor(hex: "#FF0000"), green = try DesignColor(hex: "#00FF00"), blue = try DesignColor(hex: "#0000FF")
    store.setSelection(["f"])
    let result = try await control(store, .replaceColor(from: red, to: green, ids: nil))
    #expect(result["replaced"] as? Int == 3 && colorList(result) == ["#00FF00×3", "#0000FF×2"])
    let document = store.editor.document
    #expect(document.node("f")?.fill == green && document.node("r")?.fill == green && document.node("t")?.text?.color == green)
    #expect(document.node("o")?.fill == red && document.node("r")?.stroke?.color == blue)
    #expect(store.editor.undoName == "Agent: Replace Color")
    store.undo()
    #expect(store.editor.document.node("f")?.fill == red && store.editor.document.node("t")?.text?.color == red)

    // The panel calls the same store method with the uses of the swatch it opened; a color well's stream of changes
    // coalesces into one step, and passing through red does not pick up the layers that are red.
    let blues = SelectionColors.uses(of: blue, under: ["f"], in: store.editor.document)
    let revision = store.editor.revision
    try store.setColor(red, at: blues, coalescing: "f.selectionColor.#0000FF")
    try store.setColor(green, at: blues, coalescing: "f.selectionColor.#0000FF")
    #expect(store.editor.undoName == "Change Selection Color" && store.editor.revision == revision + 2)
    #expect(store.editor.document.node("i")?.icon?.color == green && store.editor.document.node("f")?.fill == red)
    store.undo()
    #expect(store.editor.document.node("i")?.icon?.color == blue && store.editor.document.node("r")?.stroke?.color == blue)

    #expect(await failure(store, .replaceColor(from: green, to: red, ids: ["o"])) == "None of these layers or their child layers uses #00FF00")
    #expect(store.editor.document.node("o")?.fill == red)
}

@Test @MainActor func insertingAnIconAddsOneSelectedLayerAtTheViewportCenter() throws {
    let store = makeStore()
    store.insertIcon("lucide/house")
    let id = try #require(store.selection.first)
    let node = try #require(store.editor.document.node(id))
    let center = CanvasGeometry.screenToWorld(Point(x: store.canvasSize.width / 2, y: store.canvasSize.height / 2), viewport: store.viewport)
    #expect(store.selection.count == 1)
    #expect(node.type == .icon && node.name == "house" && node.icon == DesignIcon(name: "lucide/house"))
    #expect(node.frame == Rect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))
    #expect(store.editor.document.nodes.map(\.id) == [id])
    #expect(store.editor.undoName == "Insert Icon")
    store.undo()
    #expect(store.editor.document.nodes.isEmpty)
}

@Test @MainActor func insertingAnIconWithAFrameSelectedPutsItInTheFrame() throws {
    let store = makeStore()
    try store.perform("Add Frame") { try $0.insert(DesignNode(id: "f", type: .frame, x: 200, y: 200, width: 300, height: 300), parent: nil, index: nil) }
    store.setSelection(["f"])
    store.insertIcon("sf/house.fill")
    let id = try #require(store.selection.first)
    let frame = try #require(store.editor.document.node("f"))
    #expect(frame.children.map(\.id) == [id])
    #expect(frame.children.first?.frame == Rect(x: 0, y: 0, width: 24, height: 24))
    #expect(frame.children.first?.name == "house.fill")
}

@Test @MainActor func replacingAnIconKeepsFrameAndColor() throws {
    let store = makeStore()
    var node = DesignNode(id: "i", type: .icon, name: "not.a.real.symbol", x: 10, y: 20, width: 40, height: 40)
    let color = try DesignColor(hex: "#336699")
    node.icon = DesignIcon(name: "sf/not.a.real.symbol", color: color)
    var custom = node
    custom.id = "c"
    custom.name = "Back"
    try store.perform("Add Icons") {
        try $0.insert(node, parent: nil, index: nil)
        try $0.insert(custom, parent: nil, index: nil)
    }
    store.replaceIcon("i", with: "material-outlined/home")
    let replaced = try #require(store.editor.document.node("i"))
    #expect(replaced.frame == Rect(x: 10, y: 20, width: 40, height: 40))
    #expect(replaced.icon == DesignIcon(name: "material-outlined/home", color: color))
    // A name still taken from the old icon follows the new one, in the same undo step.
    #expect(replaced.name == "home")
    #expect(store.editor.undoName == "Replace Icon")
    store.undo()
    #expect(store.editor.document.node("i")?.name == "not.a.real.symbol")
    #expect(store.editor.document.node("i")?.icon?.name == "sf/not.a.real.symbol")
    // A name the person chose stays.
    store.replaceIcon("c", with: "lucide/house")
    #expect(store.editor.document.node("c")?.name == "Back")
    #expect(store.editor.document.node("c")?.icon?.name == "lucide/house")
}

@Test @MainActor func agentShowsTheLaunchWindow() async throws {
    let store = makeStore()
    var shown = 0
    store.presentLaunch = { shown += 1 }
    let result = try await control(store, .showLaunchWindow)
    #expect(shown == 1 && result["dirty"] as? Bool == false)
}

@Test @MainActor func closingTheEditorReturnsToTheLaunchWindowWithAnEmptyDocument() async throws {
    let store = makeStore()
    var launched = 0, prototypeDismissed = 0
    store.presentLaunch = { launched += 1 }
    store.dismissPrototype = { prototypeDismissed += 1 }
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "f", "type": "frame", "width": 100, "height": 100])))
    let url = temporaryFile()
    _ = try await control(store, .saveDocument(url.path))
    try store.playPrototype(from: "f")

    #expect(store.closeEditor(discarding: { Issue.record("a clean document needs no confirmation"); return false }))
    #expect(launched == 1 && prototypeDismissed == 1 && !store.prototypeWindowOpen)
    #expect(store.editor.document.nodes.isEmpty && store.fileURL == nil && !store.isDirty && store.title == "Untitled")
}

@Test @MainActor func cancellingTheCloseKeepsTheEditorAndItsUnsavedChanges() async throws {
    let store = makeStore()
    var launched = 0
    store.presentLaunch = { launched += 1 }
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    let before = store.editor.document

    #expect(!store.closeEditor(discarding: { false }))
    #expect(launched == 0 && store.editor.document == before && store.isDirty)

    #expect(store.closeEditor(discarding: { true }))
    #expect(launched == 1 && store.editor.document.nodes.isEmpty && !store.isDirty)
}

@Test @MainActor func agentClosesTheEditorWindowOnlyWithDiscardWhenUnsaved() async throws {
    let store = makeStore()
    var launched = 0, editorDismissed = 0
    store.presentLaunch = { launched += 1 }
    store.dismissEditor = { editorDismissed += 1 }
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))

    #expect(await failure(store, .closeEditorWindow(discard: false))?.contains("discard") == true)
    #expect(launched == 0 && editorDismissed == 0 && store.editor.document.node("r") != nil)

    let result = try await control(store, .closeEditorWindow(discard: true))
    #expect(launched == 1 && editorDismissed == 1 && result["dirty"] as? Bool == false)
    #expect(store.editor.document.nodes.isEmpty)
}

@Test @MainActor func agentListsOpensRemovesAndClearsRecents() async throws {
    let store = makeStore()
    let kept = temporaryFile().resolvingSymlinksInPath(), gone = temporaryFile().resolvingSymlinksInPath()
    _ = try await control(store, .saveDocument(gone.path))
    _ = try await control(store, .saveDocument(kept.path))
    try FileManager.default.removeItem(at: gone)

    // The list is the same as the launch window's, newest first, marking the file that no longer exists.
    let listed = try #require(try await control(store, .listRecents)["recents"] as? [[String: Any]])
    #expect(listed.map { $0["path"] as? String } == [kept.path, gone.path])
    #expect(listed.map { $0["name"] as? String } == [kept.deletingPathExtension().lastPathComponent, gone.deletingPathExtension().lastPathComponent])
    #expect(listed.map { $0["available"] as? Bool } == [true, false])
    #expect(store.recentEntries.map(\.available) == [true, false])
    #expect(listed.allSatisfy { ($0["openedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil })

    // A missing file or a path not in the list is an error, with no alert and no change.
    #expect(await failure(store, .openRecent(gone.path, discard: false)) == "File not found: \(gone.path) (deleted or moved); remove it from the list with app_remove_recent")
    #expect(await failure(store, .openRecent("/nowhere.fudehand", discard: false)) == "Not a recent file: /nowhere.fudehand")
    #expect(await failure(store, .removeRecent("/nowhere.fudehand")) == "Not a recent file: /nowhere.fudehand")
    #expect(store.alert == nil && store.recents.items.map(\.path) == [kept.path, gone.path] && store.fileURL == kept)

    // Unsaved changes need discard, as with open_document.
    _ = try await control(store, .newDocument(discard: false))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    #expect(await failure(store, .openRecent(kept.path, discard: false)) == "The current document has unsaved changes; save it first, or pass discard: true to discard them")
    #expect(store.editor.document.node("r") != nil && store.fileURL == nil && store.alert == nil)
    let opened = try await control(store, .openRecent(kept.path, discard: true))
    #expect(opened["file"] as? String == kept.path && opened["dirty"] as? Bool == false)
    #expect(store.editor.document.node("r") == nil)
    // Opening the current, unchanged file again only shows it.
    var presented = 0
    store.presentEditor = { presented += 1 }
    _ = try await control(store, .openRecent(kept.path, discard: false))
    #expect(presented == 1 && store.fileURL?.path == kept.path)

    let removed = try await control(store, .removeRecent(gone.path))
    #expect(removed["removed"] as? [String] == [gone.path])
    #expect((removed["recents"] as? [[String: Any]])?.map { $0["path"] as? String } == [kept.path])
    #expect(store.recents.items.map(\.path) == [kept.path])
    // Another spelling of the same file (/private/var/… for /var/…) finds the entry, which is stored with symlinks resolved.
    let unresolved = URL(fileURLWithPath: "/private" + temporaryFile().resolvingSymlinksInPath().path)
    _ = try await control(store, .saveDocument(unresolved.path))
    #expect(unresolved.path != unresolved.resolvingSymlinksInPath().path)
    _ = try await control(store, .openRecent(unresolved.path, discard: false))
    // …also once the file is gone, when its own symlinks can no longer be resolved.
    try FileManager.default.removeItem(at: unresolved)
    #expect(await failure(store, .openRecent(unresolved.path, discard: false))?.hasPrefix("File not found: ") == true)
    #expect((try await control(store, .removeRecent(unresolved.path)))["removed"] as? [String] == ["/" + unresolved.pathComponents.dropFirst(2).joined(separator: "/")])
    let cleared = try await control(store, .clearRecents)
    #expect(cleared["removed"] as? [String] == [kept.path] && (cleared["recents"] as? [Any])?.isEmpty == true)
    #expect(store.recents.items.isEmpty)
}

@Test @MainActor func agentCreatesAnUntitledDocumentFromATemplate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-templates-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let template = DesignDocument(nodes: [DesignNode(id: "f", type: .frame, x: 0, y: 0, width: 390, height: 844)])
    let templateURL = directory.appendingPathComponent("Mobile.fudehand")
    try template.encoded().write(to: templateURL)
    try template.encoded().write(to: directory.appendingPathComponent("Desktop.fudehand"))
    let original = try Data(contentsOf: templateURL)
    let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!, templateDirectory: directory)

    let listed = try #require(try await control(store, .listTemplates)["templates"] as? [[String: Any]])
    #expect(listed.map { $0["name"] as? String } == ["Desktop", "Mobile"])
    // The title is what the launch window shows; a template without a string-table entry shows its file name.
    #expect(listed.map { $0["title"] as? String } == ["Desktop", "Mobile"])
    #expect(await failure(store, .newDocumentFromTemplate("Tablet", discard: false)) == "Template not found: Tablet; available: Desktop, Mobile")

    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    #expect(await failure(store, .newDocumentFromTemplate("Mobile", discard: false)) == "The current document has unsaved changes; save it first, or pass discard: true to discard them")
    #expect(store.editor.document.node("r") != nil && store.alert == nil)

    let created = try await control(store, .newDocumentFromTemplate("Mobile", discard: true))
    #expect(created["file"] is NSNull && created["dirty"] as? Bool == false)
    #expect(store.editor.document == template && store.recents.items.isEmpty)
    // The new document is untitled: saving needs a path and never writes the template.
    _ = try await control(store, .updateNode("f", changes: JSONObject(["width": 400])))
    #expect(await failure(store, .saveDocument(nil)) == "The document has never been saved; provide path")
    #expect(try Data(contentsOf: templateURL) == original)
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-export-\(UUID().uuidString)")
}

@Test @MainActor func exportsALayerAsHTMLWithItsAssets() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "f", "type": "frame", "name": "Home", "width": 200, "height": 100, "layout": ["direction": "horizontal"],
        "children": [["id": "i", "type": "icon", "name": "Search", "icon": ["name": "lucide/search"]],
                     ["id": "s", "type": "icon", "name": "Gear", "icon": ["name": "sf/gearshape"]]],
    ])))
    let directory = temporaryDirectory().appendingPathComponent("nested")
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let document = store.editor.document
    let result = try await control(store, .exportHTML("f", directory: directory.path))
    #expect(store.editor.document == document)
    #expect(result["directory"] as? String == directory.path)
    #expect(result["files"] as? [String] == ["assets/icons/lucide-search.svg", "assets/icons/sf-gearshape.png", "index.html"])
    #expect(result["assets"] as? [String: String] == ["i": "assets/icons/lucide-search.svg", "s": "assets/icons/sf-gearshape.png"])
    let html = try String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8)
    #expect(result["html"] as? String == html)
    #expect(html.contains(#"data-layer-id="f""#))
    // The menu's path, the same store method, gives the same files.
    let again = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: again) }
    #expect(try store.exportHTML("f", to: again).files.keys.sorted() == result["files"] as? [String])
    let symbol = try Data(contentsOf: directory.appendingPathComponent("assets/icons/sf-gearshape.png"))
    #expect(NSBitmapImageRep(data: symbol)?.pixelsWide == 256)
}

@Test @MainActor func exportRefusesANonEmptyDirectoryAndUnknownLayers() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "f", "type": "frame"])))
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("keep".utf8).write(to: directory.appendingPathComponent("index.html"))
    #expect(await failure(store, .exportHTML("f", directory: directory.path)) == "Directory is not empty: \(directory.path)")
    #expect(try String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8) == "keep")
    #expect(await failure(store, .exportHTML("nope", directory: directory.path)) == "Layer not found: nope")
    let file = directory.appendingPathComponent("index.html").path
    #expect(await failure(store, .exportHTML("f", directory: file)) == "Not a directory: \(file)")
}

@Test @MainActor func focusingSeveralLayersMatchesZoomToSelection() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "a", "type": "frame", "x": 0, "y": 0, "width": 100, "height": 100])))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "b", "type": "frame", "x": 2000, "y": 900, "width": 300, "height": 200])))
    store.setSelection(["a", "b"])
    store.zoomToSelection()
    let expected = store.viewport
    store.fitAll(animated: false)
    store.setSelection([])
    let state = try await control(store, .focusNodes(["a", "b"]))
    #expect(store.viewport == expected)
    #expect(store.selection.isEmpty)
    let viewport = try #require(state["viewport"] as? [String: Double])
    #expect(viewport["scale"] == expected.scale)
    #expect(await failure(store, .focusNodes(["a", "missing"])) == "Layer not found: missing")
    #expect(store.viewport == expected)
}

@Test @MainActor func agentReadsAndSetsTheEditorView() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "f", "type": "frame", "children": [
        ["id": "g", "type": "group", "children": [["id": "r", "type": "rectangle"]]],
    ]])))
    let initial = try #require(try await control(store, .getState)["view"] as? [String: Any])
    #expect(initial["tool"] as? String == "move")
    #expect(initial["inspector"] as? Bool == true)
    #expect(initial["inspectorTab"] as? String == "design")
    #expect(initial["collapsed"] as? [String] == [])

    let result = try await control(store, .setView(ViewChange(tool: .rectangle, inspector: false, inspectorTab: .chat, collapse: ["f", "g"])))
    #expect(store.tool == .rectangle && !store.showingInspector && store.inspectorTab == .chat)
    #expect(store.collapsedLayers == ["f", "g"])
    let previous = try #require(result["previous"] as? [String: Any])
    #expect(previous["tool"] as? String == "move" && previous["inspector"] as? Bool == true)
    #expect(previous["inspectorTab"] as? String == "design" && previous["collapsed"] as? [String] == [])
    let view = try #require(result["view"] as? [String: Any])
    #expect(view["tool"] as? String == "rectangle" && view["collapsed"] as? [String] == ["f", "g"])

    // The layers panel's chevron calls the same store method.
    store.setCollapsed("g", false)
    _ = try await control(store, .setView(ViewChange(expand: ["f"])))
    #expect(store.collapsedLayers.isEmpty)

    // A bad id changes nothing, not even the valid parts of the request.
    #expect(await failure(store, .setView(ViewChange(tool: .hand, collapse: ["missing"]))) == "Layer not found: missing")
    #expect(await failure(store, .setView(ViewChange(tool: .hand, collapse: ["r"]))) == "Layer has no child layers to expand or collapse: r")
    #expect(store.tool == .rectangle && store.collapsedLayers.isEmpty)

    // Layers deleted after collapsing are not reported.
    _ = try await control(store, .setView(ViewChange(collapse: ["g"])))
    _ = try await control(store, .deleteNodes(["g"]))
    #expect((try await control(store, .getState)["view"] as? [String: Any])?["collapsed"] as? [String] == [])

    // Another document starts with every layer expanded, even where an id repeats.
    _ = try await control(store, .createNode(parent: "f", index: nil, node: JSONObject(["id": "k", "type": "rectangle"])))
    _ = try await control(store, .setView(ViewChange(collapse: ["f"])))
    _ = try await control(store, .newDocument(discard: true))
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "f", "type": "frame", "children": [["id": "c", "type": "rectangle"]]])))
    #expect(store.collapsedLayers.isEmpty)
}

// MARK: Version snapshots

@MainActor private func storeWithFrame() async throws -> FudehandStore {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject([
        "id": "home", "type": "frame", "name": "Home", "x": 100, "y": 50, "width": 120, "height": 80, "fill": "#FF0000",
        "children": [["id": "label", "type": "rectangle", "width": 10, "height": 10]],
    ])))
    return store
}

@Test @MainActor func agentSavesAVersionSnapshotAsOneUndoStep() async throws {
    let store = try await storeWithFrame()
    let saved = try await control(store, .saveVersionSnapshot(frame: "home", note: "Before the redesign"))
    let id = try #require(saved["id"] as? String)
    #expect(saved["frame"] as? String == "home" && saved["frameName"] as? String == "Home" && saved["note"] as? String == "Before the redesign")
    #expect(saved["bounds"] as? [String: Double] == ["x": 260, "y": 50, "width": 120, "height": 80])
    #expect(saved["frameBounds"] as? [String: Double] == ["x": 100, "y": 50, "width": 120, "height": 80])
    let node = try #require(store.editor.document.node(id))
    #expect(store.editor.document.nodes.last?.id == id && node.type == .image)
    // The image is the frame rendered at twice its size.
    let data = try #require(node.image?.data)
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(image.pixelsWide == 240 && image.pixelsHigh == 160)
    #expect(store.editor.undoName == "Agent: Save Version Snapshot")
    // Snapshots stay when the frame changes, and the list reads them back.
    _ = try await control(store, .updateNode("home", changes: JSONObject(["fill": "#0000FF"])))
    let listed = try await control(store, .listVersionSnapshots(frame: "home"))
    #expect((listed["snapshots"] as? [[String: Any]])?.map { $0["id"] as? String } == [id])
    store.undo()
    store.undo()
    #expect(store.editor.document.versionSnapshots().isEmpty)
}

@Test @MainActor func onlyFramesHaveVersionSnapshots() async throws {
    let store = try await storeWithFrame()
    #expect(await failure(store, .saveVersionSnapshot(frame: "label", note: ""))
            == "Layer label is a rectangle, not a frame; only frames have version snapshots")
    #expect(await failure(store, .saveVersionSnapshot(frame: "nope", note: "")) == "Layer not found: nope")
    store.setSelection(["label"])
    store.saveVersionSnapshotOfSelection()
    #expect(store.alert == "Select one frame to save a version snapshot.")
    #expect(store.editor.document.versionSnapshots().isEmpty)
}

@Test @MainActor func theMenuSavesTheSelectedFrameAndSelectsTheSnapshot() async throws {
    let store = try await storeWithFrame()
    store.setSelection(["home"])
    store.saveVersionSnapshotOfSelection()
    let snapshot = try #require(store.editor.document.versionSnapshots(of: "home").first)
    #expect(store.selection == [snapshot.id] && store.editor.undoName == "Save Version Snapshot" && store.alert == nil)
    // A second one lines up to the right of the first.
    store.setSelection(["home"])
    store.saveVersionSnapshotOfSelection()
    let both = store.editor.document.versionSnapshots(of: "home")
    #expect(both.count == 2 && both[1].x == snapshot.frame.maxX + VersionSnapshot.gap)
}

@Test @MainActor func aVersionSnapshotCanBeOverlaidOnItsFrameAndPutBack() async throws {
    let store = try await storeWithFrame()
    let saved = try await control(store, .saveVersionSnapshot(frame: "home", note: ""))
    let id = try #require(saved["id"] as? String)
    store.compareVersionSnapshot(id, overlay: true)
    var node = try #require(store.editor.document.node(id))
    #expect(node.x == 100 && node.y == 50 && node.opacity == 0.5 && store.editor.undoName == "Overlay Snapshot on Frame")
    store.compareVersionSnapshot(id, overlay: false)
    node = try #require(store.editor.document.node(id))
    #expect(node.x == 260 && node.y == 50 && node.opacity == 1)
    // The note is edited like any other field, by the panel or by design_update_node.
    _ = try await control(store, .updateNode(id, changes: JSONObject(["versionSnapshot": ["note": "Old header"]])))
    #expect(store.editor.document.node(id)?.versionSnapshot?.note == "Old header")
    // Once the frame is gone the snapshot stays, and the list says its frame is gone.
    _ = try await control(store, .deleteNodes(["home"]))
    let result = try await control(store, .listVersionSnapshots(frame: nil))
    let listed = try #require(result["snapshots"] as? [[String: Any]])
    #expect(listed.count == 1 && listed[0]["frameName"] is NSNull && listed[0]["frameBounds"] is NSNull)
}

/// The inspector and the Agent edit effects the same way, each change one undo step (#190).
@Test @MainActor func effectEditsFromThePanelAndTheAgentAreOneUndoStepEach() async throws {
    let store = makeStore()
    _ = try await control(store, .createNode(parent: nil, index: nil, node: JSONObject(["id": "r", "type": "rectangle"])))
    store.updateNode("r", "Add Effect") { $0.effects.append(DesignEffect(type: .dropShadow)) }
    let updated = try await control(store, .updateNode("r", changes: JSONObject(["effects": [["type": "background-blur", "radius": 20]]])))
    #expect((updated["effects"] as? [[String: Any]])?.first?["type"] as? String == "background-blur")
    store.undo()
    #expect(store.editor.document.node("r")?.effects == [DesignEffect(type: .dropShadow)])
    store.undo()
    #expect(store.editor.document.node("r")?.effects.isEmpty == true)
}

/// The panels look layers up in `documentIndex` (#227): it always describes `document`, so during a drag it holds the
/// positions from before the drag, like the panels did, and catches up when the drag ends.
@Test @MainActor func thePanelIndexFollowsThePublishedDocument() {
    let store = makeStore()
    store.replace(DesignDocument(nodes: [DesignNode(id: "a", type: .rectangle, x: 10, y: 20, width: 30, height: 40)]), url: nil)
    #expect(store.documentIndex.node("a")?.x == 10)
    store.canvasBeginGesture("Move Layers")
    store.canvasMove(["a": Point(x: 50, y: 20)])
    #expect(store.index.node("a")?.x == 50)
    #expect(store.documentIndex.node("a")?.x == 10 && store.document.node("a")?.x == 10)
    store.canvasEndGesture()
    #expect(store.documentIndex.node("a")?.x == 50 && store.document.node("a")?.x == 50)
    store.updateNode("a", "Rename Layer") { $0.name = "Box" }
    #expect(store.documentIndex.node("a")?.name == "Box")
    store.undo()
    #expect(store.documentIndex.node("a")?.name == store.document.node("a")?.name)
}

// MARK: Components

/// A store holding frame "home" with rectangle "card" (fill red) and text "label", and an empty frame "page".
@MainActor private func makeComponentStore() throws -> FudehandStore {
    let store = makeStore()
    var home = DesignNode(id: "home", type: .frame, x: 0, y: 0, width: 300, height: 300)
    var card = DesignNode(id: "card", type: .rectangle, x: 10, y: 10, width: 50, height: 40)
    card.fill = try DesignColor(hex: "#FF0000")
    home.children = [card]
    let page = DesignNode(id: "page", type: .frame, x: 400, y: 0, width: 300, height: 300)
    try store.perform("Setup") { document in
        try document.insert(home, parent: nil, index: nil)
        try document.insert(page, parent: nil, index: nil)
    }
    return store
}

@Test @MainActor func createComponentViaControlMatchesUI() async throws {
    let store = try makeComponentStore()
    let viaControl = try await control(store, .createComponent("card"))
    #expect(viaControl["component"] as? Bool == true)
    #expect(store.editor.undoName == "Agent: Create Component")
    store.undo()
    #expect(store.editor.document.node("card")?.component == false)
    let node = try store.createComponent("card")
    #expect(node.component && store.editor.undoName == "Create Component")
    #expect(store.editor.document.node("card")?.component == true)
}

@Test @MainActor func createInstanceViaControlIsOneAgentStep() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("card")
    let created = try await control(store, .createInstance(component: "card", parent: "page", index: nil, x: 20, y: 30))
    let id = try #require(created["id"] as? String)
    let instance = try #require(store.editor.document.node(id))
    #expect(instance.instance == "card" && instance.source == "card" && instance.x == 20 && instance.y == 30)
    #expect(store.editor.document.parentID(of: id) == .some("page"))
    #expect(store.editor.undoName == "Agent: Insert Component" && store.selection == [id])
    store.undo()
    #expect(store.editor.document.node(id) == nil)
    // Without x, y, or a parent the instance is placed as an inserted layer is: at the viewport center, at the top level.
    let placed = try store.createInstance(of: "card", parent: nil, index: nil, at: nil)
    #expect(store.editor.document.parentID(of: placed.id) == .some(nil) && store.editor.undoName == "Insert Component")
    // With a parent and no position, it sits at the parent's origin.
    let inParent = try store.createInstance(of: "card", parent: "page", index: nil, at: nil)
    #expect(store.editor.document.node(inParent.id)?.x == 0 && store.editor.document.node(inParent.id)?.y == 0)
}

@Test @MainActor func createInstanceRefusesWhatIsNotAMainComponentOrWouldNest() async throws {
    let store = try makeComponentStore()
    #expect(await failure(store, .createInstance(component: "card", parent: nil, index: nil, x: nil, y: nil)) == "Layer card is not a main component")
    #expect(await failure(store, .createInstance(component: "nope", parent: nil, index: nil, x: nil, y: nil)) == "Layer not found: nope")
    _ = try store.createComponent("home")
    #expect(await failure(store, .createInstance(component: "home", parent: "home", index: nil, x: nil, y: nil)) != nil)
    #expect(store.editor.document.node("home")?.children.count == 1)
}

@Test @MainActor func resetOverridesViaControl() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("home")
    let instance = try store.createInstance(of: "home", parent: "page", index: nil, at: nil)
    let child = try #require(store.editor.document.node(instance.id)?.children.first?.id)
    store.updateNode(child, "Change Fill") { $0.fill = try? DesignColor(hex: "#00FF00") }
    #expect(store.editor.document.node(child)?.overrides.contains("fill") == true)
    let result = try await control(store, .resetOverrides(child, properties: ["fill"]))
    #expect(result["id"] as? String == child)
    #expect(store.editor.document.node(child)?.overrides.isEmpty == true)
    let red = try DesignColor(hex: "#FF0000")
    #expect(store.editor.document.node(child)?.fill == red)
    #expect(store.editor.undoName == "Agent: Reset Overrides")
    #expect(await failure(store, .resetOverrides("home", properties: nil)) == "Layer home is not inside an instance")
    #expect(await failure(store, .resetOverrides(child, properties: ["nonsense"])) == "Unknown property: nonsense")
    // The instance root with no property list resets every layer of it.
    store.updateNode(child, "Change Fill") { $0.fill = try? DesignColor(hex: "#00FF00") }
    _ = try await control(store, .resetOverrides(instance.id, properties: nil))
    #expect(store.editor.document.node(child)?.overrides.isEmpty == true)
}

@Test @MainActor func detachViaControl() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("home")
    let first = try store.createInstance(of: "home", parent: "page", index: nil, at: Point(x: 0, y: 0))
    let second = try store.createInstance(of: "home", parent: "page", index: nil, at: Point(x: 10, y: 10))
    let result = try await control(store, .detachInstance([first.id, second.id]))
    #expect((result["ids"] as? [String]) == [first.id, second.id])
    for id in [first.id, second.id] {
        let node = try #require(store.editor.document.node(id))
        #expect(node.instance == nil && node.source == nil && node.children.allSatisfy { $0.source == nil })
    }
    #expect(store.editor.undoName == "Agent: Detach Instance")
    store.undo()
    #expect(store.editor.document.node(first.id)?.instance == "home")
    #expect(await failure(store, .detachInstance(["page"])) == "Layer page is not an instance")
    let child = try #require(store.editor.document.node(first.id)?.children.first?.id)
    #expect(await failure(store, .detachInstance([child])) == "Layer \(child) is inside instance \(first.id); detach that instance instead")
}

@Test @MainActor func listComponentsCountsNestedCopies() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("card")
    // A second main component holding an instance of "card".
    var box = DesignNode(id: "box", type: .frame, x: 0, y: 400, width: 100, height: 100)
    box.children = []
    try store.perform("Add box") { try $0.insert(box, parent: nil, index: nil) }
    _ = try store.createComponent("box")
    let inner = try store.createInstance(of: "card", parent: "box", index: nil, at: Point(x: 0, y: 0))
    let outer = try store.createInstance(of: "box", parent: "page", index: nil, at: Point(x: 0, y: 0))
    let list = try #require(try await store.handleControl(.listComponents) as? [String: Any])["components"] as? [[String: Any]]
    let byID = Dictionary(uniqueKeysWithValues: try #require(list).map { ($0["id"] as! String, $0) })
    #expect(byID["box"]?["instances"] as? [String] == [outer.id])
    let cardInstances = try #require(byID["card"]?["instances"] as? [String])
    // The instance inside "box", and its copy inside the instance of "box".
    #expect(cardInstances.count == 2 && cardInstances.contains(inner.id))
    #expect(byID["card"]?["width"] as? Double == 50 && byID["card"]?["name"] as? String == store.editor.document.node("card")?.name)
    #expect(store.listComponents().map(\.component.id) == ["card", "box"])
}

@Test @MainActor func createComponentInsideInstanceFails() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("home")
    let instance = try store.createInstance(of: "home", parent: "page", index: nil, at: nil)
    let child = try #require(store.editor.document.node(instance.id)?.children.first?.id)
    #expect(await failure(store, .createComponent(child)) == "Layer \(child) is inside instance \(instance.id); change its main component instead")
    #expect(await failure(store, .createComponent(instance.id)) == "Layer \(instance.id) is an instance; detach it first")
    #expect(await failure(store, .createComponent("home")) == "Layer home is already a main component")
    #expect(await failure(store, .createComponent("card")) == "Layer card is inside main component home; a main component cannot be inside another main component")
    #expect(await failure(store, .createComponent("nope")) == "Layer not found: nope")
    #expect(store.editor.undoName == "Insert Component")
}

@Test @MainActor func selectionDropsLayersRemovedBySync() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("home")
    let instance = try store.createInstance(of: "home", parent: "page", index: nil, at: nil)
    let child = try #require(store.editor.document.node(instance.id)?.children.first?.id)
    store.setSelection([child])
    store.updateNode("home", "Clear") { $0.children = [] }
    #expect(store.editor.document.node(child) == nil && store.selection.isEmpty)
}

@Test @MainActor func defaultPlacementSkipsASelectedInstance() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("home")
    // The first instance stays selected; the next default-placed ones go to the top level, not into it.
    let first = try await control(store, .createInstance(component: "home", parent: nil, index: nil, x: nil, y: nil))
    let second = try await control(store, .createInstance(component: "home", parent: nil, index: nil, x: nil, y: nil))
    let firstID = try #require(first["id"] as? String), secondID = try #require(second["id"] as? String)
    #expect(store.editor.document.parentID(of: firstID) == .some(nil) && store.editor.document.parentID(of: secondID) == .some(nil))
    store.setSelection([secondID])
    store.insertIcon("sf/star")
    let icon = try #require(store.selection.first)
    #expect(store.editor.document.parentID(of: icon) == .some(nil))
    // A selected main component still takes new layers.
    store.setSelection(["page"])
    #expect(store.insertionPlacement(width: 1, height: 1).parent == "page")
    store.setSelection(["home"])
    #expect(store.insertionPlacement(width: 1, height: 1).parent == "home")
}

@Test @MainActor func resetOverridesOnANestedCopyGoesBackToTheOuterMainComponent() async throws {
    let store = try makeComponentStore()
    _ = try store.createComponent("card")
    var box = DesignNode(id: "box", type: .frame, x: 0, y: 400, width: 100, height: 100)
    box.children = []
    try store.perform("Add box") { try $0.insert(box, parent: nil, index: nil) }
    _ = try store.createComponent("box")
    _ = try store.createInstance(of: "card", parent: "box", index: nil, at: Point(x: 0, y: 0))
    let outer = try store.createInstance(of: "box", parent: "page", index: nil, at: Point(x: 0, y: 0))
    let copy = try #require(store.editor.document.node(outer.id)?.children.first)
    let blue = try DesignColor(hex: "#0000FF")
    store.updateNode(copy.id, "Change Fill") { $0.fill = blue }
    #expect(store.editor.document.node(copy.id)?.overrides.contains("fill") == true)
    _ = try await control(store, .resetOverrides(copy.id, properties: ["fill"]))
    let red = try DesignColor(hex: "#FF0000")
    #expect(store.editor.document.node(copy.id)?.fill == red)
    // Nothing left to reset: no new undo step.
    let name = store.editor.undoName
    _ = try await control(store, .resetOverrides(copy.id, properties: nil))
    #expect(store.editor.undoName == name)
}
