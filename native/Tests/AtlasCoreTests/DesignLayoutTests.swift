import Foundation
import Testing
import AtlasCore

/// 每个字符宽 10、每行高 20；给出最大宽度时按宽度折行。
let fakeMeasure: TextMeasure = { text, maxWidth in
    let natural = Double(text.content.count) * 10
    guard let maxWidth, maxWidth > 0 else { return Size(width: natural, height: 20) }
    let lines = max(1, (natural / maxWidth).rounded(.up))
    return Size(width: min(natural, maxWidth), height: lines * 20)
}

private func box(_ id: String, _ width: Double, _ height: Double) -> DesignNode {
    DesignNode(id: id, type: .rectangle, width: width, height: height)
}

private func autoFrame(_ layout: AutoLayout, sizing: Sizing = .fixed, width: Double = 200, height: Double = 200,
                       children: [DesignNode]) -> DesignNode {
    var frame = DesignNode(id: "f", type: .frame, width: width, height: height)
    frame.layout = layout
    frame.sizing = sizing
    frame.children = children
    return frame
}

private func laidOut(_ node: DesignNode) -> DesignNode {
    var nodes = [node]
    DesignLayout.apply(to: &nodes, measure: fakeMeasure)
    return nodes[0]
}

@Test func verticalHugFrame() {
    let frame = laidOut(autoFrame(AutoLayout(direction: .vertical, spacing: 12, padding: EdgeInsets(top: 16, right: 16, bottom: 16, left: 16)),
                                  sizing: Sizing(horizontal: .hug, vertical: .hug), children: [box("a", 80, 50), box("b", 60, 50)]))
    #expect(frame.height == 144 && frame.width == 112)
    #expect(frame.children.map { Point(x: $0.x, y: $0.y) } == [Point(x: 16, y: 16), Point(x: 16, y: 78)])
}

@Test func fillChildrenShareRemainingSpace() {
    var a = box("a", 10, 10), b = box("b", 10, 10)
    a.sizing.horizontal = .fill; b.sizing.horizontal = .fill
    let frame = laidOut(autoFrame(AutoLayout(direction: .horizontal, spacing: 10, padding: EdgeInsets(left: 10)),
                                  width: 230, children: [a, box("fixed", 50, 10), b]))
    #expect(frame.children.map(\.width) == [75, 50, 75])
    #expect(frame.children.map(\.x) == [10, 95, 155])
}

@Test func crossStretchAndCenter() {
    let stretched = laidOut(autoFrame(AutoLayout(direction: .vertical, padding: EdgeInsets(right: 20, left: 20), crossAlign: .stretch),
                                      children: [box("a", 10, 10)]))
    #expect(stretched.children[0].width == 160 && stretched.children[0].x == 20)
    let centered = laidOut(autoFrame(AutoLayout(direction: .vertical, crossAlign: .center), children: [box("a", 50, 10)]))
    #expect(centered.children[0].x == 75)
}

@Test func spaceBetweenAndEnd() {
    let between = laidOut(autoFrame(AutoLayout(direction: .horizontal, align: .spaceBetween), children: [box("a", 20, 10), box("b", 20, 10), box("c", 20, 10)]))
    #expect(between.children.map(\.x) == [0, 90, 180])
    let end = laidOut(autoFrame(AutoLayout(direction: .vertical, spacing: 10, align: .end), children: [box("a", 10, 40), box("b", 10, 40)]))
    #expect(end.children.map(\.y) == [110, 160])
}

@Test func hiddenChildrenDoNotTakeSpace() {
    var hidden = box("h", 10, 100)
    hidden.visible = false
    let frame = laidOut(autoFrame(AutoLayout(direction: .vertical, spacing: 10), sizing: Sizing(vertical: .hug), children: [hidden, box("a", 10, 30)]))
    #expect(frame.height == 30 && frame.children[1].y == 0)
}

@Test func textAutoWidthAndWrappingHeight() {
    var text = DesignNode(id: "t", type: .text, width: 1, height: 1)
    text.text = DesignText(content: "12345")
    #expect(laidOut(text).width == 50 && laidOut(text).height == 20)
    text.text?.autoResize = .height
    text.width = 20
    #expect(laidOut(text).height == 60)
}

@Test func fillWidthTextHeightFollowsParentWidth() {
    var text = DesignNode(id: "t", type: .text)
    text.text = DesignText(content: "1234567890", autoResize: .height)
    text.sizing = Sizing(horizontal: .fill, vertical: .fixed)
    var frame = autoFrame(AutoLayout(direction: .vertical), sizing: Sizing(vertical: .hug), width: 100, children: [text])
    #expect(laidOut(frame).height == 20)
    frame.width = 50
    let narrow = laidOut(frame)
    #expect(narrow.children[0].width == 50 && narrow.children[0].height == 40 && narrow.height == 40)
}

@Test func stretchedTextWrapsAtParentWidth() {
    var text = DesignNode(id: "t", type: .text)
    text.text = DesignText(content: String(repeating: "字", count: 50))
    let frame = laidOut(autoFrame(AutoLayout(direction: .vertical, crossAlign: .stretch), sizing: Sizing(vertical: .hug), children: [text]))
    #expect(frame.children[0].width == 200 && frame.children[0].height == 60 && frame.height == 60)
}

@Test func groupShrinksToChildren() {
    var group = DesignNode(id: "g", type: .group, x: 100, y: 100, width: 1, height: 1)
    var a = box("a", 10, 10); a.x = 20; a.y = 30
    var b = box("b", 10, 10); b.x = 50; b.y = 40
    group.children = [a, b]
    let result = laidOut(group)
    #expect(result.frame == Rect(x: 120, y: 130, width: 40, height: 20))
    #expect(result.children.map { Point(x: $0.x, y: $0.y) } == [Point(x: 0, y: 0), Point(x: 30, y: 10)])
}
