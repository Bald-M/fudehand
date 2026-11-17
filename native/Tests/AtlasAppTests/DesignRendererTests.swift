import AppKit
import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

@MainActor private func sample() -> [DesignNode] {
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 100)
    frame.fill = .white
    var title = DesignNode(id: "t", type: .text, x: 10, y: 10, width: 80, height: 20)
    title.text = DesignText(content: "标题")
    var dot = DesignNode(id: "e", type: .ellipse, x: 150, y: 10, width: 20, height: 20)
    dot.fill = .black
    frame.children = [title, dot]
    return [frame, DesignNode(id: "r", type: .rectangle, x: 300, y: 0)]
}

@Test @MainActor func syncCreatesOneLayerPerNodeInOrder() {
    let renderer = DesignRenderer()
    renderer.sync(sample())
    #expect(renderer.layerCount == 4)
    #expect(renderer.root.sublayers?.count == 2)
    #expect(renderer.layer(for: "f")?.sublayers?.count == 2)
    #expect(renderer.layer(for: "e") is CAShapeLayer)
    #expect(renderer.layer(for: "t") is TextLayer)
    #expect(renderer.layer(for: "f")?.masksToBounds == true)
    #expect(renderer.layer(for: "r")?.frame == CGRect(x: 300, y: 0, width: 100, height: 100))
}

@Test @MainActor func syncReusesLayersAndRemovesDeletedOnes() {
    let renderer = DesignRenderer()
    var nodes = sample()
    renderer.sync(nodes)
    let frameLayer = renderer.layer(for: "f")
    nodes[0].children[1].visible = false
    nodes[0].x = 40
    nodes.removeLast()
    renderer.sync(nodes)
    #expect(renderer.layer(for: "f") === frameLayer)
    #expect(frameLayer?.position == CGPoint(x: 40, y: 0))
    #expect(renderer.layer(for: "e")?.isHidden == true)
    #expect(renderer.layer(for: "r") == nil && renderer.layerCount == 3)
    // 层叠顺序跟随数组顺序。
    nodes[0].children.reverse()
    renderer.sync(nodes)
    #expect(renderer.layer(for: "f")?.sublayers?.first === renderer.layer(for: "e"))
}

@Test @MainActor func snapshotRendersNodeAtScale() throws {
    var frame = sample()[0]
    frame.x = 500
    let png = try DesignRenderer.snapshotPNG(frame, scale: 2)
    let image = try #require(NSBitmapImageRep(data: png))
    #expect(image.pixelsWide == 400 && image.pixelsHigh == 200)
    // 白色背景，右上角的黑色圆点（画布 160,20 → 像素 320,40）。
    let background = try #require(image.colorAt(x: 20, y: 180)?.usingColorSpace(.sRGB))
    #expect(background.redComponent > 0.95)
    let dot = try #require(image.colorAt(x: 320, y: 40)?.usingColorSpace(.sRGB))
    #expect(dot.redComponent < 0.05 && dot.alphaComponent > 0.95)
}

@Test @MainActor func snapshotDrawsTextUprightAtTheTop() throws {
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 100)
    frame.fill = .white
    var text = DesignNode(id: "t", type: .text, x: 0, y: 0, width: 200, height: 30)
    text.text = DesignText(content: "■■■■■■■■", fontSize: 24, autoResize: .none)
    frame.children = [text]
    let image = try #require(NSBitmapImageRep(data: try DesignRenderer.snapshotPNG(frame, scale: 1)))
    func darkPixels(rows: Range<Int>) -> Int {
        rows.reduce(0) { total, y in total + (0..<200).filter { (image.colorAt(x: $0, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5 }.count }
    }
    #expect(darkPixels(rows: 0..<35) > 200)
    #expect(darkPixels(rows: 40..<100) == 0)
}

@Test func textMeasureWrapsToWidth() {
    let text = DesignText(content: "一二三四五六七八九十", fontSize: 16)
    let single = TextMetrics.measure(text, nil)
    let wrapped = TextMetrics.measure(text, single.width / 2)
    #expect(single.height > 0 && single.width > 100)
    #expect(wrapped.height >= single.height * 2 - 1)
    #expect(TextMetrics.measure(DesignText(content: ""), nil).height > 0)
}
