import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// A store holding frame "home" at (0, 0) with rectangle "card" at (10, 10), on a private pasteboard.
@MainActor private func makeStore() throws -> FudehandStore {
    let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!)
    store.pasteboard = NSPasteboard(name: NSPasteboard.Name("fudehand-tests-\(UUID().uuidString)"))
    var home = DesignNode(id: "home", type: .frame, x: 0, y: 0, width: 300, height: 300)
    var card = DesignNode(id: "card", type: .rectangle, x: 10, y: 10, width: 50, height: 50)
    card.effects = [DesignEffect(type: .dropShadow)]
    home.children = [card]
    try store.perform("Setup") { try $0.insert(home, parent: nil, index: nil) }
    return store
}

@MainActor private func control(_ store: FudehandStore, _ command: ControlCommand) async throws -> [String: Any] {
    try #require(try await store.handleControl(command) as? [String: Any])
}

@MainActor private func failure(_ store: FudehandStore, _ command: ControlCommand) async -> String? {
    do { _ = try await store.handleControl(command); return nil } catch { return error.localizedDescription }
}

@Test @MainActor func copyAndPasteFromTheUIMakesASelectedCopyAsOneUndoStep() throws {
    let store = try makeStore()
    store.setSelection(["card"])
    store.canvasCopy(store.selection, cut: false)
    #expect(store.canPasteLayers && store.editor.undoName == "Setup")
    store.paste()
    let copy = try #require(store.selection.first)
    #expect(store.selection.count == 1 && copy != "card" && store.alert == nil)
    #expect(store.editor.document.parentID(of: copy) == .some("home"))
    #expect(store.editor.document.worldRect(copy) == Rect(x: 20, y: 20, width: 50, height: 50))
    #expect(store.editor.document.node(copy)?.effects.count == 1)
    #expect(store.editor.undoName == "Paste Layers")
    store.undo()
    #expect(store.editor.document.node(copy) == nil && store.editor.document.node("card") != nil)
}

@Test @MainActor func agentCopyAndPasteMatchTheUI() async throws {
    let store = try makeStore()
    store.setSelection(["card"])
    let copied = try await control(store, .copyNodes(ids: nil, cut: false))
    #expect(copied["copied"] as? [String] == ["card"] && copied["cut"] as? Bool == false)
    let first = try await control(store, .paste)
    let ids = try #require(first["ids"] as? [String])
    #expect(ids.count == 1 && store.selection == Set(ids) && store.editor.undoName == "Agent: Paste Layers")
    #expect((first["nodes"] as? [[String: Any]])?.first?["x"] as? Double == 20)
    // Pasting again moves another step instead of going into the copy just pasted.
    let second = try #require(try await control(store, .paste)["ids"] as? [String])
    #expect(store.editor.document.parentID(of: second[0]) == .some("home"))
    #expect(store.editor.document.node(second[0])?.x == 30)
}

@Test @MainActor func cutDeletesAndPasteRestoresInPlace() async throws {
    let store = try makeStore()
    _ = try await control(store, .copyNodes(ids: ["card"], cut: true))
    #expect(store.editor.document.node("card") == nil && store.editor.undoName == "Agent: Cut Layers")
    let ids = try #require(try await control(store, .paste)["ids"] as? [String])
    #expect(store.editor.document.worldRect(ids[0]) == Rect(x: 10, y: 10, width: 50, height: 50))
    // Each is its own undo step.
    store.undo()
    store.undo()
    #expect(store.editor.document.node("card") != nil)
}

@Test @MainActor func duplicateCopiesInPlaceWithoutTheClipboard() async throws {
    let store = try makeStore()
    let changeCount = store.pasteboard.changeCount
    store.setSelection(["card"])
    store.duplicateSelection()
    let ui = try #require(store.selection.first)
    #expect(store.editor.document.worldRect(ui) == Rect(x: 20, y: 20, width: 50, height: 50))
    #expect(store.editor.undoName == "Duplicate Layers")
    let agent = try #require(try await control(store, .duplicateNodes(ids: ["card"]))["ids"] as? [String])
    #expect(store.editor.document.worldRect(agent[0]) == Rect(x: 20, y: 20, width: 50, height: 50))
    #expect(store.editor.undoName == "Agent: Duplicate Layers" && store.selection == Set(agent))
    #expect(store.pasteboard.changeCount == changeCount && !store.canPasteLayers)
}

@Test @MainActor func pasteReachesAnotherDocument() async throws {
    let store = try makeStore()
    _ = try await control(store, .copyNodes(ids: ["home"], cut: false))
    store.replace(DesignDocument(), url: nil)
    let ids = try #require(try await control(store, .paste)["ids"] as? [String])
    let copy = try #require(store.editor.document.node(ids[0]))
    #expect(store.editor.document.nodes.count == 1 && copy.children.count == 1 && copy.children[0].id != "card")
}

@Test @MainActor func clipboardCommandsExplainFailures() async throws {
    let store = try makeStore()
    #expect(await failure(store, .paste) == "The clipboard holds no layers")
    #expect(await failure(store, .copyNodes(ids: nil, cut: false)) == "Nothing is selected; select layers or pass ids")
    #expect(await failure(store, .duplicateNodes(ids: ["missing"])) == "Layer not found: missing")
    #expect(store.editor.undoName == "Setup")
}

@Test @MainActor func cutPasteMainComponentKeepsLinks() throws {
    let store = try makeStore()
    var main = DesignNode(id: "m", type: .frame, x: 400, y: 0, width: 100, height: 40)
    main.component = true
    main.children = [DesignNode(id: "t", type: .rectangle, x: 4, y: 4, width: 10, height: 10)]
    var existing = store.editor.document.allIDs().union(["m", "t", "i"])
    var instance = ComponentSync.makeInstance(of: main, existing: &existing)
    instance.id = "i"
    instance.x = 600
    try store.perform("Setup") {
        try $0.insert(main, parent: nil, index: nil)
        try $0.insert(instance, parent: nil, index: nil)
    }
    try store.copyLayers(["m"], cut: true)
    // The cut leaves the instance pointing at the missing main component.
    #expect(store.editor.document.node("m") == nil)
    #expect(store.editor.document.node("i")?.instance == "m" && store.editor.document.node("i")?.children[0].source == "t")
    let ids = try store.pasteLayers()
    #expect(ids == ["m"])
    #expect(store.editor.document.node("m")?.component == true && store.editor.document.node("m")?.children[0].id == "t")
    #expect(store.editor.document.worldRect("m") == Rect(x: 400, y: 0, width: 100, height: 40))
    // The instance follows the main component again.
    try store.perform("Fill") { try $0.update("m") { $0.fill = DesignColor(r: 0, g: 0, b: 1) } }
    #expect(store.editor.document.node("i")?.fill == DesignColor(r: 0, g: 0, b: 1))
    #expect(store.editor.document.node("i")?.instance == "m")
}
