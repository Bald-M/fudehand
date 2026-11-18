import Foundation
import Testing
import FudehandCore

private func patchMessage(_ changes: [String: Any], on node: DesignNode) -> String? {
    var copy = node
    do { try DesignJSON.apply(changes, to: &copy); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func textNode() -> DesignNode {
    var node = DesignNode(id: "t", type: .text)
    node.text = DesignText(content: "Hello", fontSize: 14)
    return node
}

@Test func patchRejectsUnknownField() {
    #expect(patchMessage(["foo": 1], on: DesignNode(id: "r", type: .rectangle)) == "Layer r: unsupported field foo")
    #expect(patchMessage(["text": ["size": 3]], on: textNode()) == "Layer t: unsupported field text.size")
}

@Test func patchRejectsOutOfRangeAndWrongType() {
    let rect = DesignNode(id: "r", type: .rectangle)
    #expect(patchMessage(["opacity": 2], on: rect) == "Layer r: opacity must not be greater than 1")
    #expect(patchMessage(["x": "3"], on: rect) == "Layer r: x must be a number")
    #expect(patchMessage(["x": 1e20], on: rect) == "Layer r: x is out of range (absolute value must not exceed 1000000)")
    #expect(patchMessage(["visible": 1], on: rect) == "Layer r: visible must be true or false")
    #expect(patchMessage(["layout": ["spacing": 4]], on: DesignNode(id: "e", type: .ellipse)) == "Layer e: ellipse does not support layout")
    #expect(patchMessage(["id": "x"], on: rect) == "Layer r: cannot change id")
    #expect(patchMessage(["sizing": ["horizontal": "grow"]], on: rect)
            == "Layer r: sizing.horizontal must be one of fixed, hug, fill; got grow")
}

@Test func patchRejectsSignedColorAndFractionalFontWeight() throws {
    #expect(patchMessage(["fill": "#+12345"], on: DesignNode(id: "r", type: .rectangle))?.contains("#RRGGBB") == true)
    #expect(patchMessage(["text": ["fontWeight": 450.9]], on: textNode()) == "Layer t: text.fontWeight must be an integer")
    var node = textNode()
    try DesignJSON.apply(["text": ["fontWeight": 500.0]], to: &node)
    #expect(node.text?.fontWeight == 500)
}

@Test func patchMergesNestedFields() throws {
    var node = textNode()
    try DesignJSON.apply(["text": ["fontSize": 20], "fill": "#FF0000"], to: &node)
    #expect(node.text?.fontSize == 20 && node.text?.content == "Hello")
    #expect(node.fill == DesignColor(r: 1, g: 0, b: 0))
    try DesignJSON.apply(["fill": NSNull()], to: &node)
    #expect(node.fill == nil)
}

@Test func patchKeepsChildren() throws {
    var frame = DesignNode(id: "f", type: .frame)
    frame.children = [DesignNode(id: "c", type: .rectangle)]
    try DesignJSON.apply(["layout": ["direction": "horizontal", "spacing": 8]], to: &frame)
    #expect(frame.children.map(\.id) == ["c"])
    #expect(frame.layout == AutoLayout(direction: .horizontal, spacing: 8))
}

@Test func failedPatchLeavesNodeUnchanged() {
    var node = textNode()
    #expect(throws: DesignError.self) { try DesignJSON.apply(["opacity": 0.5, "width": -3], to: &node) }
    #expect(node == textNode())
}

@Test func buildsNestedNodeWithDefaults() throws {
    let node = try DesignJSON.node(from: ["id": "f", "type": "frame", "children": [["id": "t", "type": "text", "text": ["content": "Hi"]]]])
    #expect(node.name == "Frame" && node.width == 100 && node.clipsContent)
    #expect(node.children[0].text == DesignText(content: "Hi"))
}

@Test func describesImagesWithoutData() throws {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    let node = try DesignJSON.node(from: ["id": "i", "type": "image", "image": ["data": png.base64EncodedString()]])
    let summary = DesignJSON.object(node, includeImageData: false)["image"] as? [String: Any]
    #expect(summary?["data"] as? String == "<\(png.count) bytes>")
    #expect(throws: DesignError.self) { try DesignJSON.node(from: ["id": "i", "type": "image", "image": ["data": "aGVsbG8="]]) }
}
