import Foundation
import Testing
import FudehandCore

/// Frame f holding group g holding rectangle a, followed by a top-level ellipse b.
private func index() -> DesignIndex {
    var group = DesignNode(id: "g", type: .group, name: "Card", x: 10, y: 20, width: 60, height: 60)
    group.children = [DesignNode(id: "a", type: .rectangle, name: "Badge", x: 5, y: 5, width: 30, height: 40)]
    var frame = DesignNode(id: "f", type: .frame, name: "Home", x: 100, y: 50, width: 300, height: 300)
    frame.children = [group]
    return DesignIndex(DesignDocument(nodes: [frame, DesignNode(id: "b", type: .ellipse, name: "Dot", x: 500, y: 0)]))
}

@Test func canvasExposesTopLevelLayersWithoutASelection() {
    let items = CanvasAccessibility.items(index: index(), selection: [])
    #expect(items.map(\.id) == ["f", "b"])
    #expect(items.map(\.name) == ["Home", "Dot"] && items.map(\.type) == [.frame, .ellipse])
    #expect(items.allSatisfy { !$0.selected })
}

@Test func canvasAddsSelectedNestedLayersInTreeOrder() {
    let items = CanvasAccessibility.items(index: index(), selection: ["a", "g", "b"])
    #expect(items.map(\.id) == ["f", "b", "g", "a"])
    #expect(items.map(\.selected) == [false, true, true, true])
    #expect(items.first { $0.id == "a" }?.rect == Rect(x: 115, y: 75, width: 30, height: 40))
}

@Test func accessibilityRectFollowsTheViewport() {
    let item = CanvasAccessibility.items(index: index(), selection: []).first!
    #expect(item.viewRect(Viewport(x: -20, y: 10, scale: 2)) == Rect(x: 180, y: 110, width: 600, height: 600))
}
