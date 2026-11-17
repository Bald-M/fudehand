import Foundation
import Testing
import AtlasCore

private func editor() -> DesignEditor {
    var frame = DesignNode(id: "f", type: .frame, x: 100, y: 50, width: 300, height: 300)
    frame.children = [DesignNode(id: "a", type: .rectangle, x: 10, y: 20, width: 50, height: 50)]
    return DesignEditor(document: DesignDocument(nodes: [frame, DesignNode(id: "b", type: .ellipse, x: 500, y: 0)]), measure: fakeMeasure)
}

@Test func performIsOneUndoStep() throws {
    var e = editor()
    try e.perform("修改") { try $0.update("a") { $0.width = 80 } }
    try e.perform("修改") { try $0.update("a") { $0.height = 90 } }
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
    try e.perform("无变化") { try $0.update("a") { $0.width = 50 } }
    #expect(!e.canUndo && e.revision == revision)
    #expect(throws: DesignError.self) { try attempt(&e) { try $0.update("missing") { $0.width = 1 } } }
    #expect(!e.canUndo && e.revision == revision)
}

@Test func coalescingMergesSteps() throws {
    var e = editor()
    for width in [60.0, 70, 80] { try e.perform("填充", coalescing: "a.width") { try $0.update("a") { $0.width = width } } }
    #expect(e.undo() && e.document.node("a")?.width == 50 && !e.canUndo)
}

@Test func gestureIsOneStep() throws {
    var e = editor()
    e.beginGesture("移动图层")
    for x in [11.0, 12, 13] { e.applyLive { try? $0.update("a") { $0.x = x } } }
    e.endGesture()
    #expect(e.document.node("a")?.x == 13 && e.undoName == "移动图层")
    #expect(e.undo() && e.document.node("a")?.x == 10 && !e.canUndo)
}

@Test func performEndsOpenGesture() throws {
    var e = editor()
    e.beginGesture("移动图层")
    e.applyLive { try? $0.update("a") { $0.x = 40 } }
    try attempt(&e) { try $0.delete(["b"]) }
    #expect(e.undo() && e.document.node("b") != nil && e.document.node("a")?.x == 40)
    #expect(e.undo() && e.document.node("a")?.x == 10)
}

@Test func insertValidatesParentIndexAndIDs() throws {
    var e = editor()
    try e.perform("新建") { try $0.insert(DesignNode(id: "c", type: .text), parent: "f", index: 0) }
    #expect(e.document.node("f")?.children.map(\.id) == ["c", "a"])
    #expect(throws: DesignError("图层 id 重复：a")) { try attempt(&e) { try $0.insert(DesignNode(id: "a", type: .rectangle), parent: nil, index: nil) } }
    #expect(throws: DesignError("图层 b 不能包含子图层")) { try attempt(&e) { try $0.insert(DesignNode(id: "z", type: .rectangle), parent: "b", index: nil) } }
    #expect(throws: DesignError("找不到图层：nope")) { try attempt(&e) { try $0.insert(DesignNode(id: "z", type: .rectangle), parent: "nope", index: nil) } }
    #expect(throws: DesignError("index 超出范围：0–2")) { try attempt(&e) { try $0.insert(DesignNode(id: "z", type: .rectangle), parent: "f", index: 5) } }
}

@Test func moveKeepsWorldPositionAndRejectsCycles() throws {
    var e = editor()
    #expect(e.document.worldRect("a") == Rect(x: 110, y: 70, width: 50, height: 50))
    try e.perform("移动") { try $0.move("a", parent: nil, index: nil) }
    #expect(e.document.nodes.map(\.id) == ["f", "b", "a"])
    #expect(e.document.node("a")?.frame == Rect(x: 110, y: 70, width: 50, height: 50))
    try e.perform("移动") { try $0.move("b", parent: "f", index: 0) }
    #expect(e.document.node("b").map { Point(x: $0.x, y: $0.y) } == Point(x: 400, y: -50))
    #expect(throws: DesignError("不能把图层移动到它自己或子图层中")) { try attempt(&e) { try $0.move("f", parent: "b", index: nil) } }
    #expect(e.document.parentID(of: "b") == .some("f") && e.document.parentID(of: "f") == .some(nil))
}

@Test func deleteRemovesNestedAndReportsMissing() throws {
    var e = editor()
    #expect(throws: DesignError("找不到图层：zz")) { try attempt(&e) { try $0.delete(["a", "zz"]) } }
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
    try e.perform("自动布局") { try $0.update("f") { $0.layout = AutoLayout(direction: .vertical, padding: EdgeInsets(top: 8, left: 8)) } }
    #expect(e.document.node("a").map { Point(x: $0.x, y: $0.y) } == Point(x: 8, y: 8))
}

private func attempt(_ e: inout DesignEditor, _ change: (inout DesignDocument) throws -> Void) throws {
    try e.perform("操作", change)
}
