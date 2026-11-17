import Foundation
import Testing
import AtlasCore

private func patchMessage(_ changes: [String: Any], on node: DesignNode) -> String? {
    var copy = node
    do { try DesignJSON.apply(changes, to: &copy); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func textNode() -> DesignNode {
    var node = DesignNode(id: "t", type: .text)
    node.text = DesignText(content: "你好", fontSize: 14)
    return node
}

@Test func patchRejectsUnknownField() {
    #expect(patchMessage(["foo": 1], on: DesignNode(id: "r", type: .rectangle)) == "图层 r：不支持字段 foo")
    #expect(patchMessage(["text": ["size": 3]], on: textNode()) == "图层 t：不支持字段 text.size")
}

@Test func patchRejectsOutOfRangeAndWrongType() {
    let rect = DesignNode(id: "r", type: .rectangle)
    #expect(patchMessage(["opacity": 2], on: rect) == "图层 r：opacity 不能大于 1")
    #expect(patchMessage(["x": "3"], on: rect) == "图层 r：x 应为数字")
    #expect(patchMessage(["x": 1e20], on: rect) == "图层 r：x 超出范围（绝对值不能大于 1000000）")
    #expect(patchMessage(["visible": 1], on: rect) == "图层 r：visible 应为 true 或 false")
    #expect(patchMessage(["layout": ["spacing": 4]], on: DesignNode(id: "e", type: .ellipse)) == "图层 e：ellipse 不支持 layout")
    #expect(patchMessage(["id": "x"], on: rect) == "图层 r：不能修改 id")
    #expect(patchMessage(["sizing": ["horizontal": "grow"]], on: rect)
            == "图层 r：sizing.horizontal 应为 fixed、hug、fill 之一，收到 grow")
}

@Test func patchMergesNestedFields() throws {
    var node = textNode()
    try DesignJSON.apply(["text": ["fontSize": 20], "fill": "#FF0000"], to: &node)
    #expect(node.text?.fontSize == 20 && node.text?.content == "你好")
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
    #expect(node.name == "画框" && node.width == 100 && node.clipsContent)
    #expect(node.children[0].text == DesignText(content: "Hi"))
}

@Test func describesImagesWithoutData() throws {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    let node = try DesignJSON.node(from: ["id": "i", "type": "image", "image": ["data": png.base64EncodedString()]])
    let summary = DesignJSON.object(node, includeImageData: false)["image"] as? [String: Any]
    #expect(summary?["data"] as? String == "<\(png.count) 字节>")
    #expect(throws: DesignError.self) { try DesignJSON.node(from: ["id": "i", "type": "image", "image": ["data": "aGVsbG8="]]) }
}
