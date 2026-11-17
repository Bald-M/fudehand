import Testing
import AtlasCore

/// 顶层画框 f（0,0 300×300）内有卡片 card（10,10 200×100，含按钮 btn 20,20 50×30）和分组 g（含 dot）；
/// 顶层还有矩形 r（400,0）。
private func document() -> DesignDocument {
    var button = DesignNode(id: "btn", type: .rectangle, x: 20, y: 20, width: 50, height: 30)
    button.fill = .white
    var card = DesignNode(id: "card", type: .frame, x: 10, y: 10, width: 200, height: 100)
    card.children = [button]
    var group = DesignNode(id: "g", type: .group, x: 10, y: 200, width: 20, height: 20)
    group.children = [DesignNode(id: "dot", type: .ellipse, x: 0, y: 0, width: 20, height: 20)]
    var frame = DesignNode(id: "f", type: .frame, width: 300, height: 300)
    frame.children = [card, group]
    return DesignDocument(nodes: [frame, DesignNode(id: "r", type: .rectangle, x: 400, y: 0)])
}

private func pick(_ x: Double, _ y: Double, selection: Set<String> = [], deep: Bool = false, in doc: DesignDocument = document()) -> String? {
    DesignHitTest.selectable(path: DesignHitTest.path(at: Point(x: x, y: y), in: doc), selection: selection, document: doc, deep: deep)
}

@Test func pathFindsDeepestTopmostNode() {
    #expect(DesignHitTest.path(at: Point(x: 35, y: 35), in: document()) == ["f", "card", "btn"])
    #expect(DesignHitTest.path(at: Point(x: 250, y: 250), in: document()) == ["f"])
    #expect(DesignHitTest.path(at: Point(x: 350, y: 10), in: document()).isEmpty)
    // 分组空白处点不中分组。
    #expect(DesignHitTest.path(at: Point(x: 15, y: 205), in: document()) == ["f", "g", "dot"])
}

@Test func clickSelectsChildOfTopLevelFrame() {
    #expect(pick(35, 35) == "card")
    #expect(pick(250, 250) == "f")
    #expect(pick(450, 50) == "r")
    #expect(pick(15, 205) == "g")
}

@Test func siblingsOfSelectionAreDirectlySelectable() {
    #expect(pick(35, 35, selection: ["btn"]) == "btn")
    #expect(pick(15, 205, selection: ["dot"]) == "dot")
    #expect(pick(150, 80, selection: ["btn"]) == "card")
}

@Test func commandClickSelectsDeepest() {
    #expect(pick(35, 35, deep: true) == "btn")
}

@Test func lockedAndHiddenNodesAreSkipped() {
    var doc = document()
    try? doc.update("card") { $0.locked = true }
    #expect(pick(35, 35, in: doc) == "f")
    var hidden = document()
    try? hidden.update("btn") { $0.visible = false }
    #expect(DesignHitTest.path(at: Point(x: 35, y: 35), in: hidden) == ["f", "card"])
}

@Test func clippedChildrenOutsideFrameAreNotHit() {
    var doc = document()
    try? doc.update("btn") { $0.x = 250 }
    #expect(DesignHitTest.path(at: Point(x: 270, y: 35), in: doc) == ["f"])
    try? doc.update("card") { $0.clipsContent = false }
    #expect(DesignHitTest.path(at: Point(x: 270, y: 35), in: doc) == ["f", "card", "btn"])
}

@Test func enterSelectsNextLevel() {
    #expect(DesignHitTest.enter("card", at: Point(x: 35, y: 35), in: document()) == "btn")
    #expect(DesignHitTest.enter("btn", at: Point(x: 35, y: 35), in: document()) == nil)
}
