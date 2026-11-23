import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

@MainActor private func control(_ store: FudehandStore, _ command: ControlCommand) async throws -> [String: Any] {
    try #require(try await store.handleControl(command) as? [String: Any])
}

@MainActor private func failure(_ store: FudehandStore, _ command: ControlCommand) async -> String? {
    do { _ = try await store.handleControl(command); return nil } catch { return error.localizedDescription }
}

/// The center of an annotation's marker in canvas (screen-space) coordinates.
@MainActor private func marker(_ h: CanvasHarness, _ id: String) throws -> NSPoint {
    let anchor = try #require(h.canvas.index.annotationMarkers().first { $0.annotation.id == id }?.anchor)
    let rect = CanvasOverlay.markerRect(anchor, viewport: h.canvas.liveViewport)
    return NSPoint(x: rect.midX, y: rect.midY)
}

@Test @MainActor func annotateToolPinsADraftToTheDeepestLayerAndAddingItMakesOneUndoStep() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.store.setSelection(["b"])
    h.setTool(.annotate)
    // The card is at 20,20 inside frame a; the viewport is offset by 100 vertically.
    h.click(NSPoint(x: 50, y: 140))
    #expect(h.store.annotation == .draft(node: "card", x: 30, y: 20))
    #expect(h.store.tool == .move && h.store.selection == ["b"] && h.store.editor.document.annotations.isEmpty)
    #expect(h.canvas.overlay.expandedMarker == CanvasOverlay.draftMarker)
    #expect(throws: DesignError("text must not be empty")) { try h.store.submitAnnotationDraft(" ") }
    try h.store.submitAnnotationDraft("Make this the primary action")
    let added = try #require(h.store.editor.document.annotations.first)
    #expect(added.node == "card" && added.x == 30 && added.y == 20 && added.author == .person)
    #expect(h.store.editor.undoName == "Add Annotation" && h.store.annotation == .thread(added.id))
    #expect(h.canvas.overlay.markerCounts == [added.id: "1"] && h.canvas.overlay.expandedMarker == added.id)
    // Clicking empty canvas with the tool does nothing.
    h.setTool(.annotate)
    h.click(NSPoint(x: 500, y: 650))
    #expect(h.store.annotation == nil && h.store.editor.document.annotations.count == 1)
}

@Test @MainActor func pressingAMarkerExpandsAndCollapsesItWithoutTouchingTheSelection() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let note = try h.store.addAnnotation(on: "b", x: 10, y: 10, text: "Too wide", by: .person)
    try h.store.replyToAnnotation(note.id, text: "Agreed", by: .person)
    h.store.setSelection(["card"])
    let point = try marker(h, note.id)
    #expect(h.canvas.hitTarget(at: point) == .annotation(note.id))
    h.click(point)
    #expect(h.store.annotation == .thread(note.id) && h.store.selection == ["card"])
    #expect(h.canvas.overlay.expandedMarker == note.id && h.canvas.overlay.markerCounts == [note.id: "2"])
    // Dragging from a marker moves nothing.
    h.drag(from: point, to: NSPoint(x: point.x + 60, y: point.y + 60))
    #expect(h.node("b")?.x == 600 && h.store.annotation == nil)
    h.click(point)
    #expect(h.store.annotation == .thread(note.id))
    // A press elsewhere collapses it and goes on to select as usual.
    h.click(NSPoint(x: 50, y: 140))
    #expect(h.store.annotation == nil && h.store.selection == ["card"] && h.canvas.overlay.expandedMarker == nil)
}

@Test @MainActor func markersFollowTheirLayerAndGoWithIt() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let note = try h.store.addAnnotation(on: "b", x: 0, y: 300, text: "Bottom-left", by: .person)
    #expect(try marker(h, note.id) == NSPoint(x: 612, y: 388))
    h.drag(from: NSPoint(x: 700, y: 200), to: NSPoint(x: 750, y: 230), flags: .control)
    #expect(try marker(h, note.id) == NSPoint(x: 662, y: 418))
    h.click(try marker(h, note.id))
    #expect(h.store.annotation == .thread(note.id))
    h.store.canvasDelete(["b"])
    #expect(h.store.editor.document.annotations.isEmpty && h.canvas.overlay.markerCounts.isEmpty && h.store.annotation == nil)
    h.store.undo()
    #expect(h.store.editor.document.annotations.map(\.id) == [note.id] && h.canvas.overlay.markerCounts == [note.id: "1"])
    h.store.edit("Hide") { try $0.update("b") { $0.visible = false } }
    #expect(h.canvas.overlay.markerCounts.isEmpty)
}

@Test @MainActor func cKeyChoosesTheAnnotateTool() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    try h.key(8, chars: "c")
    #expect(h.store.tool == .annotate)
}

@Test @MainActor func agentAnnotationToolsMatchTheUIPath() async throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let store = h.store
    let added = try await control(store, .addAnnotation(node: "b", x: nil, y: nil, text: " Why 300 wide? ", replyTo: nil))
    #expect(added["node"] as? String == "b" && added["x"] as? Double == 150 && added["y"] as? Double == 150)
    #expect(added["author"] as? String == "agent" && added["text"] as? String == "Why 300 wide?")
    #expect(store.editor.undoName == "Agent: Add Annotation" && store.isDirty)
    let id = try #require(added["id"] as? String)
    _ = try await control(store, .addAnnotation(node: "card", x: 5, y: 5, text: "Card note", replyTo: nil))
    let replied = try await control(store, .addAnnotation(node: nil, x: nil, y: nil, text: "To match the grid", replyTo: id))
    let replies = try #require(replied["replies"] as? [[String: Any]])
    #expect(replies.count == 1 && replies[0]["author"] as? String == "agent" && store.editor.undoName == "Agent: Reply to Annotation")
    let replyID = try #require(replies[0]["id"] as? String)
    let edited = try await control(store, .updateAnnotation(replyID, text: "To match the 8 pt grid"))
    #expect((edited["replies"] as? [[String: Any]])?.first?["text"] as? String == "To match the 8 pt grid")
    #expect(store.editor.undoName == "Agent: Edit Annotation")
    let onB = try await control(store, .listAnnotations(node: "b"))
    #expect((onB["annotations"] as? [[String: Any]])?.map { $0["id"] as? String } == [id])
    #expect((try await control(store, .listAnnotations(node: nil))["annotations"] as? [Any])?.count == 2)
    #expect(try await control(store, .deleteAnnotation(replyID))["deleted"] as? String == replyID)
    #expect(store.editor.undoName == "Agent: Delete Annotation" && store.editor.document.annotations[0].replies.isEmpty)
    _ = try await control(store, .undo)
    #expect(store.editor.document.annotations[0].replies.count == 1)

    #expect(await failure(store, .addAnnotation(node: "zz", x: nil, y: nil, text: "x", replyTo: nil)) == "Layer not found: zz")
    #expect(await failure(store, .addAnnotation(node: "b", x: nil, y: nil, text: "  ", replyTo: nil)) == "text must not be empty")
    #expect(await failure(store, .addAnnotation(node: nil, x: nil, y: nil, text: "x", replyTo: "zz")) == "Annotation not found: zz")
    #expect(await failure(store, .updateAnnotation("zz", text: "x")) == "Annotation not found: zz")
    #expect(await failure(store, .deleteAnnotation("zz")) == "Annotation not found: zz")
    #expect(await failure(store, .listAnnotations(node: "zz")) == "Layer not found: zz")
}

@Test @MainActor func annotationsSurviveSaveAndOpen() async throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let note = try h.store.addAnnotation(on: "card", x: 1, y: 2, text: "Keep", by: .person)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-\(UUID().uuidString).fudehand")
    defer { try? FileManager.default.removeItem(at: url) }
    try h.store.write(to: url)
    h.store.replace(DesignDocument(), url: nil)
    #expect(h.store.editor.document.annotations.isEmpty)
    try await h.store.open(url)
    #expect(h.store.editor.document.annotations == [note] && h.canvas.overlay.markerCounts == [note.id: "1"])
}

@Test @MainActor func voiceOverListsMarkersAfterLayersAndPressingOneExpandsIt() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let note = try h.store.addAnnotation(on: "b", x: 10, y: 10, text: "Too wide", by: .person)
    let children = try #require(h.canvas.accessibilityChildren())
    let element = try #require(children.last as? CanvasAnnotationElement)
    #expect(children.count == 3 && element.id == note.id && element.accessibilityLabel() == "Annotation: Too wide")
    #expect(element.accessibilityRole() == .button)
    #expect(element.accessibilityPerformPress() && h.store.annotation == .thread(note.id))
    #expect(h.canvas.accessibilityAnnotations().first?.accessibilityValue() as? String == "Expanded")
    #expect(element.accessibilityPerformPress() && h.store.annotation == nil)
}

@Test @MainActor func threadsCollapseWhenTheirMarkerGoesAway() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let note = try h.store.addAnnotation(on: "card", x: 1, y: 1, text: "Hide me", by: .person)
    h.store.expandAnnotation(.thread(note.id))
    h.store.edit("Hide") { try $0.update("a") { $0.visible = false } }
    #expect(h.store.annotation == nil && h.canvas.annotation == nil)
    h.store.undo()
    h.store.expandAnnotation(.thread(note.id))
    h.store.undo()
    #expect(h.store.editor.document.annotations.isEmpty && h.store.annotation == nil)
    h.store.expandAnnotation(.draft(node: "card", x: 1, y: 1))
    h.store.edit("Hide") { try $0.update("card") { $0.visible = false } }
    #expect(h.store.annotation == nil)
}

@Test @MainActor func escCollapsesBeforeSelectingTheParentAndDoubleClickKeepsItOpen() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let note = try h.store.addAnnotation(on: "b", x: 10, y: 10, text: "Esc", by: .person)
    h.store.setSelection(["card"])
    let point = try marker(h, note.id)
    h.click(point)
    h.send(.leftMouseDown, at: point, clicks: 2)
    h.send(.leftMouseUp, at: point, clicks: 2)
    #expect(h.store.annotation == .thread(note.id))
    try h.key(53)
    #expect(h.store.annotation == nil && h.store.selection == ["card"])
    try h.key(53)
    #expect(h.store.selection == ["a"])
}

@Test @MainActor func aNewCanvasStartsCollapsed() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    let note = try h.store.addAnnotation(on: "b", x: 10, y: 10, text: "Reopen", by: .person)
    h.store.expandAnnotation(.thread(note.id))
    let canvas = FudehandCanvasView(frame: h.window.contentLayoutRect)
    defer { canvas.dispose() }
    h.store.attach(canvas)
    #expect(h.store.annotation == nil && canvas.annotation == nil)
}
