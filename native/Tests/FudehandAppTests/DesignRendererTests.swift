import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

@MainActor private func sample() -> [DesignNode] {
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 100)
    frame.fill = .white
    var title = DesignNode(id: "t", type: .text, x: 10, y: 10, width: 80, height: 20)
    title.text = DesignText(content: "Title")
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
    // The stacking order follows the array order.
    nodes[0].children.reverse()
    renderer.sync(nodes)
    #expect(renderer.layer(for: "f")?.sublayers?.first === renderer.layer(for: "e"))
}

@Test @MainActor func syncHandlesReplacedRetypedAndReparentedNodes() {
    let renderer = DesignRenderer()
    var nodes = sample()
    renderer.sync(nodes)
    let dot = renderer.layer(for: "e")
    // One node deleted and one added in the same sync: the count is unchanged, and the deleted layer still goes away.
    nodes[1] = DesignNode(id: "n", type: .rectangle, x: 300, y: 0)
    renderer.sync(nodes)
    #expect(renderer.layer(for: "r") == nil && renderer.layer(for: "n") != nil && renderer.layerCount == 4)
    #expect(renderer.root.sublayers?.count == 2)
    // A node that changes type gets a new layer; one that moves to another parent keeps its layer.
    nodes[1].type = .ellipse
    nodes.append(nodes[0].children.removeLast())
    renderer.sync(nodes)
    #expect(renderer.layer(for: "n") is CAShapeLayer && renderer.layerCount == 4)
    #expect(renderer.layer(for: "e") === dot && dot?.superlayer === renderer.root)
    #expect(renderer.layer(for: "f")?.sublayers?.count == 1 && renderer.root.sublayers?.count == 3)
}

@Test @MainActor func snapshotRendersNodeAtScale() throws {
    var frame = sample()[0]
    frame.x = 500
    let png = try DesignRenderer.snapshotPNG(frame, scale: 2)
    let image = try #require(NSBitmapImageRep(data: png))
    #expect(image.pixelsWide == 400 && image.pixelsHigh == 200)
    // White background, with the black dot at the top right (canvas 160,20 → pixel 320,40).
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
    let text = DesignText(content: "one two three four five six seven eight nine ten", fontSize: 16)
    let single = TextMetrics.measure(text, nil)
    let wrapped = TextMetrics.measure(text, single.width / 2)
    #expect(single.height > 0 && single.width > 100)
    #expect(wrapped.height >= single.height * 2 - 1)
    #expect(TextMetrics.measure(DesignText(content: ""), nil).height > 0)
}

/// The strokes of "▀" are in the upper half of the line and those of "▄" in the lower half; when text is upside down their vertical relationship is reversed.
@Test @MainActor func snapshotTextIsNotUpsideDown() throws {
    func inkCenterY(_ content: String) throws -> Double {
        var frame = DesignNode(id: "f", type: .frame, width: 120, height: 60)
        frame.fill = .white
        var text = DesignNode(id: "t", type: .text, width: 120, height: 60)
        text.text = DesignText(content: content, fontSize: 40, autoResize: .none)
        frame.children = [text]
        let image = try #require(NSBitmapImageRep(data: try DesignRenderer.snapshotPNG(frame, scale: 1)))
        var total = 0.0, count = 0.0
        for y in 0..<60 { for x in 0..<120 where (image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 1) < 0.5 { total += Double(y); count += 1 } }
        return count == 0 ? -1 : total / count
    }
    let upper = try inkCenterY("▀▀"), lower = try inkCenterY("▄▄")
    #expect(upper >= 0 && lower >= 0)
    #expect(upper + 5 < lower)
}

@Test @MainActor func largeLayersAreRasterizedBelowTheBitmapLimit() {
    #expect(DesignRenderer.rasterScale(8, for: CGSize(width: 100, height: 20)) == 8)
    #expect(DesignRenderer.rasterScale(8, for: CGSize(width: 4096, height: 100)) == 2)
    #expect(DesignRenderer.rasterScale(8, for: CGSize(width: 100_000, height: 100)) == 1)
}

private let redSVG = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="48" height="24"><rect width="48" height="24" fill="#FF0000"/></svg>"##.utf8)

@MainActor private func svgImage(width: Double = 48, height: Double = 24) -> DesignNode {
    var node = DesignNode(id: "s", type: .image, width: width, height: height)
    node.image = DesignImage(data: redSVG)
    return node
}

@Test @MainActor func imageSizeIsHalfThePixelsForBitmapsAndTheDeclaredSizeForSVG() throws {
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
    #expect(DesignRenderer.imageSize(png) == CGSize(width: 0.5, height: 0.5))
    #expect(DesignRenderer.imageSize(redSVG) == CGSize(width: 48, height: 24))
    let viewBoxOnly = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>"#.utf8)
    #expect(DesignRenderer.imageSize(viewBoxOnly) == CGSize(width: 24, height: 24))
    #expect(DesignRenderer.imageSize(Data("<html></html>".utf8)) == nil)
}

@Test @MainActor func svgIsRasterizedAgainWhenZoomSettlesOrTheLayerGrows() throws {
    let renderer = DesignRenderer()
    renderer.contentsScale = 1
    var node = svgImage()
    renderer.sync([node])
    let layer = try #require(renderer.layer(for: "s"))
    #expect((layer.contents as! CGImage).width == 48)
    renderer.contentsScale = 8
    #expect((layer.contents as! CGImage).width == 384)
    // Growing redraws with 1.5× headroom (768 needed → 1152), so a little more growth reuses that raster.
    node.width = 96
    node.height = 48
    renderer.sync([node])
    let grown = layer.contents as! CGImage
    #expect(grown.width == 1152)
    node.width = 120
    node.height = 60
    renderer.sync([node])
    #expect(layer.contents as! CGImage === grown)
    // Shrinking keeps the sharper raster.
    node.width = 48
    node.height = 24
    renderer.sync([node])
    #expect(layer.contents as! CGImage === grown)
}

@Test @MainActor func svgFollowsImageFitAndCornerRadius() throws {
    let renderer = DesignRenderer()
    var node = svgImage(width: 100, height: 100)
    node.cornerRadius = 10
    node.image?.fit = .fit
    renderer.sync([node])
    let layer = try #require(renderer.layer(for: "s"))
    #expect(layer.contentsGravity == .resizeAspect && layer.cornerRadius == 10 && layer.masksToBounds)
    // Fill covers the bounds, so the raster is as tall as the layer: 100 × scale 2.
    node.image?.fit = .fill
    renderer.sync([node])
    #expect(layer.contentsGravity == .resizeAspectFill && (layer.contents as! CGImage).height == 200)
}

@Test @MainActor func snapshotIncludesSVGContentUpright() throws {
    // Red on top, blue below, so an upside-down raster fails.
    var node = svgImage()
    node.image?.data = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="48" height="24"><rect width="48" height="12" fill="#FF0000"/><rect y="12" width="48" height="12" fill="#0000FF"/></svg>"##.utf8)
    let image = try #require(NSBitmapImageRep(data: try DesignRenderer.snapshotPNG(node, scale: 4)))
    #expect(image.pixelsWide == 192 && image.pixelsHigh == 96)
    // Compare the stored bytes: colorAt reports sRGB data as calibrated RGB, so converting it would shift saturated colors.
    let bytes = try #require(image.bitmapData)
    func pixel(_ x: Int, _ y: Int) -> [UInt8] { (0..<4).map { bytes[y * image.bytesPerRow + x * image.samplesPerPixel + $0] } }
    #expect(pixel(96, 20) == [255, 0, 0, 255])
    #expect(pixel(96, 76) == [0, 0, 255, 255])
}

@Test @MainActor func snapshotDrawsBitmapImagesUpright() throws {
    // A PNG with red on top and blue below, made from the same drawing as the SVG test.
    let svg = try #require(NSImage(data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="48" height="24"><rect width="48" height="12" fill="#FF0000"/><rect y="12" width="48" height="12" fill="#0000FF"/></svg>"##.utf8)))
    let tiff = try #require(svg.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    var node = DesignNode(id: "p", type: .image, width: 48, height: 24)
    node.image = DesignImage(data: png)
    let image = try #require(NSBitmapImageRep(data: try DesignRenderer.snapshotPNG(node, scale: 4)))
    let bytes = try #require(image.bitmapData)
    #expect(bytes[20 * image.bytesPerRow + 96 * image.samplesPerPixel] == 255)
    #expect(bytes[76 * image.bytesPerRow + 96 * image.samplesPerPixel + 2] == 255)
}
