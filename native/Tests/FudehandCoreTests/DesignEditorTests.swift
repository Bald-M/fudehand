import Foundation
import Testing
import FudehandCore

private func editor() -> DesignEditor {
    var frame = DesignNode(id: "f", type: .frame, x: 100, y: 50, width: 300, height: 300)
    frame.children = [DesignNode(id: "a", type: .rectangle, x: 10, y: 20, width: 50, height: 50)]
    return DesignEditor(document: DesignDocument(nodes: [frame, DesignNode(id: "b", type: .ellipse, x: 500, y: 0)]), measure: fakeMeasure)
}

@Test func performIsOneUndoStep() throws {
    var e = editor()
    try e.perform("Change") { try $0.update("a") { $0.width = 80 } }
    try e.perform("Change") { try $0.update("a") { $0.height = 90 } }
    #expect(e.canUndo && !e.canRedo)
    #expect(e.undo() && e.document.node("a")?.height == 50 && e.document.node("a")?.width == 80)
    #expect(e.undo() && e.document.node("a")?.width == 50)
    #expect(e.undo() == false)
    #expect(e.redo() && e.document.node("a")?.width == 80)
    try attempt(&e) { try $0.delete(["b"]) }
    #expect(!e.canRedo)
}

@Test func unchangedPerformAddsNoStepAndFailureChangesNothing() throws {
    var e = editor()
    let revision = e.revision
    try e.perform("No Change") { try $0.update("a") { $0.width = 50 } }
    #expect(!e.canUndo && e.revision == revision)
    #expect(throws: DesignError.self) { try attempt(&e) { try $0.update("missing") { $0.width = 1 } } }
    #expect(!e.canUndo && e.revision == revision)
}

@Test func coalescingMergesSteps() throws {
    var e = editor()
    for width in [60.0, 70, 80] { try e.perform("Fill", coalescing: "a.width") { try $0.update("a") { $0.width = width } } }
    #expect(e.undo() && e.document.node("a")?.width == 50 && !e.canUndo)
}

@Test func gestureIsOneStep() throws {
    var e = editor()
    e.beginGesture("Move Layers")
    for x in [11.0, 12, 13] { e.applyLive { try? $0.update("a") { $0.x = x } } }
    e.endGesture()
    #expect(e.document.node("a")?.x == 13 && e.undoName == "Move Layers")
    #expect(e.undo() && e.document.node("a")?.x == 10 && !e.canUndo)
}

@Test func performEndsOpenGesture() throws {
    var e = editor()
    e.beginGesture("Move Layers")
    e.applyLive { try? $0.update("a") { $0.x = 40 } }
    try attempt(&e) { try $0.delete(["b"]) }
    #expect(e.undo() && e.document.node("b") != nil && e.document.node("a")?.x == 40)
    #expect(e.undo() && e.document.node("a")?.x == 10)
}

@Test func dragContinuesAsItsOwnStepAfterAnEditArrivesMidGesture() throws {
    var e = editor()
    e.beginGesture("Move Layers")
    e.applyLive { try? $0.update("a") { $0.x = 20 } }
    try e.perform("Delete") { try $0.delete(["b"]) }
    e.applyLive { try? $0.update("a") { $0.x = 30 } }
    e.endGesture()
    #expect(e.undoName == "Move Layers")
    #expect(e.undo() && e.document.node("a")?.x == 20 && e.document.node("b") == nil)
    #expect(e.undo() && e.document.node("b") != nil && e.document.node("a")?.x == 20)
    #expect(e.undo() && e.document.node("a")?.x == 10)
}

@Test func insertValidatesParentIndexAndIDs() throws {
    var e = editor()
    try e.perform("Create") { try $0.insert(DesignNode(id: "c", type: .text), parent: "f", index: 0) }
    #expect(e.document.node("f")?.children.map(\.id) == ["c", "a"])
    #expect(throws: DesignError("Duplicate layer id: a")) { try attempt(&e) { try $0.insert(DesignNode(id: "a", type: .rectangle), parent: nil, index: nil) } }
    #expect(throws: DesignError("Layer b cannot contain child layers")) { try attempt(&e) { try $0.insert(DesignNode(id: "z", type: .rectangle), parent: "b", index: nil) } }
    #expect(throws: DesignError("Layer not found: nope")) { try attempt(&e) { try $0.insert(DesignNode(id: "z", type: .rectangle), parent: "nope", index: nil) } }
    #expect(throws: DesignError("index out of range: 0–2")) { try attempt(&e) { try $0.insert(DesignNode(id: "z", type: .rectangle), parent: "f", index: 5) } }
}

@Test func moveKeepsWorldPositionAndRejectsCycles() throws {
    var e = editor()
    #expect(e.document.worldRect("a") == Rect(x: 110, y: 70, width: 50, height: 50))
    try e.perform("Move") { try $0.move("a", parent: nil, index: nil) }
    #expect(e.document.nodes.map(\.id) == ["f", "b", "a"])
    #expect(e.document.node("a")?.frame == Rect(x: 110, y: 70, width: 50, height: 50))
    try e.perform("Move") { try $0.move("b", parent: "f", index: 0) }
    #expect(e.document.node("b").map { Point(x: $0.x, y: $0.y) } == Point(x: 400, y: -50))
    #expect(throws: DesignError("Cannot move a layer into itself or its descendants")) { try attempt(&e) { try $0.move("f", parent: "b", index: nil) } }
    #expect(e.document.parentID(of: "b") == .some("f") && e.document.parentID(of: "f") == .some(nil))
}

@Test func deleteRemovesNestedAndReportsMissing() throws {
    var e = editor()
    #expect(throws: DesignError("Layer not found: zz")) { try attempt(&e) { try $0.delete(["a", "zz"]) } }
    #expect(e.document.node("a") != nil)
    try attempt(&e) { try $0.delete(["a", "f"]) }
    #expect(e.document.allIDs() == ["b"])
}

@Test func newIDsAreUnique() {
    var existing: Set<String> = []
    for _ in 0..<200 { existing.insert(DesignDocument.newID(existing: existing)) }
    #expect(existing.count == 200 && existing.allSatisfy { $0.count == 8 })
}

@Test func replaceClearsHistory() throws {
    var e = editor()
    try attempt(&e) { try $0.delete(["b"]) }
    e.replace(DesignDocument())
    #expect(!e.canUndo && e.document.nodes.isEmpty)
}

@Test func editsRunLayout() throws {
    var e = editor()
    try e.perform("Auto Layout") { try $0.update("f") { $0.layout = AutoLayout(direction: .vertical, padding: EdgeInsets(top: 8, left: 8)) } }
    #expect(e.document.node("a").map { Point(x: $0.x, y: $0.y) } == Point(x: 8, y: 8))
}

private func attempt(_ e: inout DesignEditor, _ change: (inout DesignDocument) throws -> Void) throws {
    try e.perform("Edit", change)
}

// MARK: Coordinate range (#56)

/// Edited documents must survive a save → reopen round trip; opening lays the document out again.
private func reopened(_ e: DesignEditor) throws -> DesignDocument {
    DesignEditor(document: try DesignDocument.decode(try e.document.encoded()), measure: fakeMeasure).document
}

@Test func movingOutOfAFarFrameStaysWithinRange() throws {
    var p = DesignNode(id: "p", type: .frame, x: 900_000, y: 0, width: 200_000, height: 100)
    p.children = [DesignNode(id: "c", type: .rectangle, x: 150_000, y: 0)]
    var e = DesignEditor(document: DesignDocument(nodes: [p]), measure: fakeMeasure)
    try e.perform("Move") { try $0.move("c", parent: nil, index: nil) }
    #expect(e.document.node("c")?.x == DesignJSON.maximumMagnitude)
    #expect(try reopened(e) == e.document)
}

@Test func hugFrameWiderThanTheRangeStaysWithinRange() throws {
    var f = DesignNode(id: "f", type: .frame)
    f.layout = AutoLayout(direction: .horizontal)
    f.sizing = Sizing(horizontal: .hug, vertical: .hug)
    f.children = ["a", "b", "c"].map { DesignNode(id: $0, type: .rectangle, width: 600_000, height: 100) }
    let e = DesignEditor(document: DesignDocument(nodes: [f]), measure: fakeMeasure)
    #expect(e.document.node("f")?.width == DesignJSON.maximumMagnitude)
    #expect(try reopened(e) == e.document)
}

@Test func groupShrinkAndLiveDragStayWithinRange() throws {
    var g = DesignNode(id: "g", type: .group, x: 900_000, y: 0)
    g.children = [DesignNode(id: "a", type: .rectangle, x: 0, y: 0), DesignNode(id: "b", type: .rectangle, x: 0, y: 0)]
    var e = DesignEditor(document: DesignDocument(nodes: [g]), measure: fakeMeasure)
    e.beginGesture("Move")
    e.applyLive { try? $0.update("a") { $0.x = 500_000; $0.y = -3_000_000 } }
    e.applyLive { try? $0.update("b") { $0.x = 2_500_000 } }
    e.endGesture()
    #expect(try reopened(e) == e.document)
}

/// An edit lays out only the top-level layers it changed, which keeps edits cheap in large documents; `layOutAgain` lays out
/// every layer, for when text measures differently (#228).
@Test func editsLayOutOnlyTheTopLevelLayersTheyChange() throws {
    final class Log { var measured: [String] = [] }
    let log = Log()
    let measure: TextMeasure = { text, maxWidth in
        log.measured.append(text.content)
        return fakeMeasure(text, maxWidth)
    }
    func frame(_ id: String) -> DesignNode {
        var label = DesignNode(id: "\(id)-label", type: .text)
        label.text = DesignText(content: id, autoResize: .widthAndHeight)
        var frame = DesignNode(id: id, type: .frame, width: 300, height: 300)
        frame.children = [label]
        return frame
    }
    var e = DesignEditor(document: DesignDocument(nodes: [frame("one"), frame("two")]), measure: measure)
    #expect(Set(log.measured) == ["one", "two"])

    log.measured = []
    try e.perform("Edit Text") { try $0.update("one-label") { $0.text?.content = "first" } }
    #expect(Set(log.measured) == ["first"])
    #expect(e.document.node("one-label")?.width == 50 && e.document.node("two-label")?.width == 30)

    log.measured = []
    e.beginGesture("Move Layers")
    e.applyLive { try? $0.update("two") { $0.x = 40 } }
    e.endGesture()
    #expect(Set(log.measured) == ["two"])

    log.measured = []
    e.layOutAgain()
    #expect(Set(log.measured) == ["first", "two"])
    #expect(e.undoName == "Move Layers")
}

/// A document undo brings back from before `layOutAgain` was measured differently, so the next edit lays out every layer
/// rather than only the ones it changed (#228).
@Test func editsAfterUndoingPastLayOutAgainLayOutEveryLayer() throws {
    final class Scale { var factor = 1.0 }
    let scale = Scale()
    let measure: TextMeasure = { text, maxWidth in
        let size = fakeMeasure(text, maxWidth)
        return Size(width: size.width * scale.factor, height: size.height)
    }
    var label = DesignNode(id: "label", type: .text)
    label.text = DesignText(content: "abc", autoResize: .widthAndHeight)
    var e = DesignEditor(document: DesignDocument(nodes: [label, DesignNode(id: "box", type: .rectangle)]), measure: measure)
    try e.perform("Rename") { try $0.update("label") { $0.name = "Title" } }
    // The fonts change: text now measures twice as wide.
    scale.factor = 2
    e.layOutAgain()
    #expect(e.document.node("label")?.width == 60)
    #expect(e.undo() && e.document.node("label")?.width == 30)
    try e.perform("Move") { try $0.update("box") { $0.x = 10 } }
    #expect(e.document.node("label")?.width == 60)
}

// MARK: Components

/// Main component `m` (a hugging auto-layout frame with text `t`) and its instance `i`; the instance's layers have fresh ids.
private func componentEditor() -> DesignEditor {
    var main = DesignNode(id: "m", type: .frame, width: 100, height: 40)
    main.component = true
    main.layout = AutoLayout(direction: .horizontal)
    main.sizing = Sizing(horizontal: .hug, vertical: .hug)
    var label = DesignNode(id: "t", type: .text)
    label.text = DesignText(content: "OK", autoResize: .widthAndHeight)
    main.children = [label]
    var existing: Set<String> = ["m", "t", "i"]
    var instance = ComponentSync.makeInstance(of: main, existing: &existing)
    instance.id = "i"
    instance.x = 300
    return DesignEditor(document: DesignDocument(nodes: [main, instance]), measure: fakeMeasure)
}

@Test func mainComponentEditIsOneUndoStep() throws {
    var e = componentEditor()
    let blue = DesignColor(r: 0, g: 0, b: 1)
    try e.perform("Fill") { try $0.update("m") { $0.fill = blue } }
    #expect(e.document.node("i")?.fill == blue)
    #expect(e.undo() && e.document.node("i")?.fill == nil && e.document.node("m")?.fill == nil)
    #expect(!e.canUndo)
}

@Test func undoRestoresInstancesAndIDs() throws {
    var e = componentEditor()
    let before = e.document
    try e.perform("Insert") { try $0.insert(DesignNode(id: "r", type: .rectangle), parent: "m", index: nil) }
    let added = try #require(e.document.node("i")?.children.last)
    #expect(added.source == "r" && added.id != "r")
    let after = e.document
    #expect(e.undo() && e.document == before)
    #expect(e.redo() && e.document == after)
}

@Test func dragInMainComponentIsOneStep() throws {
    var e = componentEditor()
    try e.perform("Layout") { try $0.update("m") { $0.layout = nil; $0.sizing = .fixed } }
    e.beginGesture("Move Layers")
    for x in [11.0, 12, 13] {
        e.applyLive { try? $0.update("t") { $0.x = x } }
        #expect(e.document.node("i")?.children.first?.x == x)
    }
    e.endGesture()
    #expect(e.undoName == "Move Layers")
    #expect(e.undo() && e.document.node("i")?.children.first?.x == 0)
    #expect(e.undoName == "Layout")
}

@Test func overriddenTextReflowsInstanceLayout() throws {
    var e = componentEditor()
    let labelID = try #require(e.document.node("i")?.children.first?.id)
    try e.perform("Text") { try $0.update(labelID) { $0.text?.content = "Much longer" } }
    let main = try #require(e.document.node("m"))
    let instance = try #require(e.document.node("i"))
    #expect(instance.children[0].overrides == ["text.content"])
    #expect(instance.width > main.width)
    #expect(instance.children[0].width == 110)
}

@Test func switchIsOneUndoStep() throws {
    func variant(_ id: String, _ state: String) -> DesignNode {
        var node = DesignNode(id: id, type: .frame, x: 16, y: 16, width: 100, height: 40)
        node.component = true
        node.variant = ["State": state]
        var label = DesignNode(id: "\(id)t", type: .text, name: "Label", width: 40, height: 20)
        label.text = DesignText(content: "OK")
        node.children = [label]
        return node
    }
    let blue = DesignColor(r: 0, g: 0, b: 1)
    var on = variant("v2", "On")
    on.fill = blue
    var set = DesignNode(id: "s", type: .frame, width: 300, height: 200)
    set.componentSet = ["State"]
    set.children = [variant("v1", "Off"), on]
    var existing: Set<String> = ["s", "v1", "v1t", "v2", "v2t", "i"]
    var instance = ComponentSync.makeInstance(of: set.children[0], existing: &existing)
    instance.id = "i"
    instance.x = 400
    var e = DesignEditor(document: DesignDocument(nodes: [set, instance]), measure: fakeMeasure)
    let label = instance.children[0].id
    try e.perform("Text") { try $0.update(label) { $0.text?.content = "Go" } }
    let before = e.document
    try e.perform("Switch Variant") { try ComponentVariants.switchInstances(["i"], to: ["State": "On"], in: &$0) }
    let switched = try #require(e.document.node("i"))
    #expect(e.undoName == "Switch Variant")
    #expect(switched.instance == "v2" && switched.fill == blue && switched.overrides.isEmpty && switched.x == 400)
    #expect(switched.children[0].id == label && switched.children[0].overrides == ["text.content"])
    #expect(switched.children[0].text?.content == "Go")
    let after = e.document
    #expect(e.undo() && e.document == before && e.undoName == "Text")
    #expect(e.redo() && e.document == after)
}
