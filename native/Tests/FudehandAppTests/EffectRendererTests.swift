import AppKit
import FudehandCore
import Testing
@testable import FudehandApp

@MainActor private func snapshot(_ node: DesignNode, scale: Double = 1) throws -> NSBitmapImageRep {
    try #require(NSBitmapImageRep(data: try DesignRenderer.snapshotPNG(node, scale: scale)))
}

/// The sRGB bytes at a pixel, compared raw: colorAt reports sRGB data as calibrated RGB.
private func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    (0..<4).map { Int(image.bitmapData![y * image.bytesPerRow + x * image.samplesPerPixel + $0]) }
}

/// A white stage with a card at (40, 40), 80 × 60.
private func stage(_ card: DesignNode) -> DesignNode {
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 160)
    frame.fill = .white
    frame.children = [card]
    return frame
}

private func card(_ effects: [DesignEffect], type: NodeType = .rectangle) -> DesignNode {
    var node = DesignNode(id: "c", type: type, x: 40, y: 40, width: 80, height: 60)
    node.fill = DesignColor(r: 1, g: 0, b: 0)
    node.effects = effects
    return node
}

@Test @MainActor func effectsWrapTheLayerAndUnwrapWhenRemoved() throws {
    let renderer = DesignRenderer()
    var node = card([DesignEffect(type: .dropShadow), DesignEffect(type: .innerShadow), DesignEffect(type: .layerBlur)])
    renderer.sync([node])
    let wrapper = try #require(renderer.layer(for: "c"))
    let content = try #require(renderer.contentLayer(for: "c"))
    #expect(wrapper !== content && content.superlayer === wrapper && wrapper.superlayer === renderer.root)
    // The wrapper carries placement and the layer blur; the drop shadow sits under the content, the inner shadow inside it.
    #expect(wrapper.frame == CGRect(x: 40, y: 40, width: 80, height: 60) && content.frame == CGRect(x: 0, y: 0, width: 80, height: 60))
    #expect(wrapper.sublayers?.count == 2 && wrapper.sublayers?.last === content && wrapper.filters?.count == 1)
    #expect(content.sublayers?.count == 1 && content.backgroundColor != nil)
    node.opacity = 0.5
    node.x = 60
    renderer.sync([node])
    #expect(renderer.layer(for: "c") === wrapper && wrapper.opacity == 0.5 && content.opacity == 1 && wrapper.position.x == 100)
    // Hidden effects draw nothing, so the node goes back to a single layer.
    for index in node.effects.indices { node.effects[index].visible = false }
    renderer.sync([node])
    #expect(renderer.layer(for: "c") === content && content.superlayer === renderer.root && content.opacity == 0.5)
    #expect(content.sublayers == nil || content.sublayers?.isEmpty == true)
    #expect(content.frame == CGRect(x: 60, y: 40, width: 80, height: 60))
}

@Test @MainActor func dropShadowFallsOutsideTheLayerOnly() throws {
    var effect = DesignEffect(type: .dropShadow, color: DesignColor(r: 0, g: 0, b: 0, a: 0.5), x: 0, y: 10, radius: 0, spread: 0)
    let image = try snapshot(stage(card([effect])))
    // Below the card, within the 10 pt offset: half-transparent black over white.
    #expect(abs(pixel(image, 80, 105)[0] - 128) < 4)
    // Beside the card and inside it: untouched.
    #expect(pixel(image, 30, 70) == [255, 255, 255, 255])
    #expect(pixel(image, 80, 70) == [255, 0, 0, 255])
    // Spread grows the shadow on every side.
    effect.y = 0
    effect.spread = 6
    let spread = try snapshot(stage(card([effect])))
    #expect(pixel(spread, 37, 70)[0] < 140 && pixel(spread, 30, 70) == [255, 255, 255, 255])
}

@Test @MainActor func dropShadowIsNotDrawnUnderASeeThroughFill() throws {
    var node = card([DesignEffect(type: .dropShadow, color: .black, x: 0, y: 0, radius: 8)])
    node.fill = DesignColor(r: 1, g: 0, b: 0, a: 0.5)
    let image = try snapshot(stage(node))
    // Half-transparent red over white, no darkening from the shadow under it.
    #expect(pixel(image, 80, 70)[1] > 120)
}

@Test @MainActor func innerShadowDarkensTheInsideEdge() throws {
    let image = try snapshot(stage(card([DesignEffect(type: .innerShadow, color: .black, x: 0, y: 6, radius: 0)])))
    // The top 6 pt inside the card are shadowed; the rest keeps its fill, and nothing is drawn outside.
    #expect(pixel(image, 80, 43)[0] < 10)
    #expect(pixel(image, 80, 70) == [255, 0, 0, 255])
    #expect(pixel(image, 80, 36) == [255, 255, 255, 255])
}

@Test @MainActor func layerBlurSoftensTheEdges() throws {
    let sharp = try snapshot(stage(card([])))
    let blurred = try snapshot(stage(card([DesignEffect(type: .layerBlur, radius: 16)])))
    #expect(pixel(sharp, 36, 70) == [255, 255, 255, 255])
    // Red bleeds out past the left edge, and the edge itself is no longer full red.
    #expect(pixel(blurred, 36, 70)[1] < 250)
    #expect(pixel(blurred, 40, 70)[1] > 40)
    #expect(pixel(blurred, 80, 70) == [255, 0, 0, 255])
}

@Test @MainActor func backgroundBlurBlursWhatIsBehindTheLayer() throws {
    // Black and white stripes 4 pt wide, under a see-through card with a background blur.
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 160)
    frame.fill = .white
    frame.children = (0..<50).map { index in
        var stripe = DesignNode(id: "s\(index)", type: .rectangle, x: Double(index * 8), y: 0, width: 4, height: 160)
        stripe.fill = .black
        return stripe
    }
    var glass = card([DesignEffect(type: .backgroundBlur, radius: 20)])
    glass.fill = nil
    glass.cornerRadius = 20
    frame.children.append(glass)
    let image = try snapshot(frame)
    // Outside the card the stripes stay sharp; under it they even out to one grey (averaged in linear light, so lighter than 128).
    #expect(pixel(image, 9, 20)[0] < 10 && pixel(image, 13, 20)[0] > 245)
    for x in 76..<84 { #expect((170...205).contains(pixel(image, x, 70)[0])) }
    // The blur keeps to the rounded corners.
    #expect(pixel(image, 41, 41)[0] < 10)
}

@Test @MainActor func textShadowFollowsTheGlyphs() throws {
    var text = DesignNode(id: "t", type: .text, x: 20, y: 20, width: 160, height: 40)
    text.text = DesignText(content: "■■■■", fontSize: 30, color: .white, autoResize: .none)
    text.effects = [DesignEffect(type: .dropShadow, color: .black, x: 0, y: 30, radius: 0)]
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 120)
    frame.fill = .white
    frame.children = [text]
    let image = try snapshot(frame)
    // Black glyph-shaped shadow 30 pt below the white glyphs; nothing past the end of the line.
    let dark = (0..<200).filter { pixel(image, $0, 75)[0] < 60 }.count
    #expect(dark > 40)
    #expect(pixel(image, 190, 75) == [255, 255, 255, 255])
}

@Test @MainActor func snapshotScalesEffects() throws {
    let image = try snapshot(stage(card([DesignEffect(type: .dropShadow, color: DesignColor(r: 0, g: 0, b: 0, a: 0.5), x: 0, y: 10, radius: 0)])), scale: 2)
    #expect(image.pixelsWide == 400)
    #expect(abs(pixel(image, 160, 210)[0] - 128) < 4)
    #expect(pixel(image, 160, 224) == [255, 255, 255, 255])
}

@Test @MainActor func backgroundBlursKeepTheirPlaybackAnimationWhenRebuilt() throws {
    let renderer = DesignRenderer()
    var node = card([DesignEffect(type: .backgroundBlur)])
    renderer.sync([node])
    let backdrop = try #require(renderer.backdrops(for: "c").first)
    #expect(backdrop.superlayer === renderer.root && renderer.root.sublayers?.firstIndex(of: backdrop) == 0)
    backdrop.add(CABasicAnimation(keyPath: "opacity"), forKey: "fudehand.animation")
    // A hover state changing the fill rebuilds the blur, which keeps the animation.
    node.fill = .white
    renderer.sync([node])
    let rebuilt = try #require(renderer.backdrops(for: "c").first)
    #expect(rebuilt !== backdrop && rebuilt.animation(forKey: "fudehand.animation") != nil)
}

@Test @MainActor func noiseDrawsTheTileFromTheTopLeftCornerInsideTheShape() throws {
    let effect = DesignEffect(type: .noise, color: DesignColor(r: 0, g: 0, b: 0), size: 2, density: 0.5, seed: 3)
    var node = card([effect])
    node.fill = .white
    let image = try snapshot(stage(node))
    let cells = NoiseTile.cells(density: 0.5, seed: 3)
    // Each 2 pt cell of the 80 × 60 card, sampled at its center: white darkened by the grain's strength, or plain white.
    for row in 0..<30 {
        for column in 0..<40 {
            let strength = Int(cells[row * NoiseTile.side + column])
            let red = pixel(image, 40 + column * 2 + 1, 40 + row * 2 + 1)[0]
            #expect(abs(red - (255 - strength)) <= 3, "cell \(column),\(row): \(red) for strength \(strength)")
        }
    }
    // The grains are clipped to the shape: an ellipse leaves its bounding box's corners untouched.
    let round = try snapshot(stage(card([DesignEffect(type: .noise, color: DesignColor(r: 0, g: 0, b: 0), density: 1)], type: .ellipse)))
    #expect(pixel(round, 41, 41) == [255, 255, 255, 255])
    #expect(pixel(round, 80, 70)[0] < 255)
}

@Test @MainActor func noiseSitsBelowTheChildLayers() throws {
    let renderer = DesignRenderer()
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    frame.effects = [DesignEffect(type: .noise)]
    frame.children = [DesignNode(id: "child", type: .rectangle, width: 10, height: 10)]
    renderer.sync([frame])
    let content = try #require(renderer.contentLayer(for: "f"))
    // One tile repeat covers the 100 pt frame, and the child layer stays above the grains.
    let grains = try #require(content.sublayers?.first)
    #expect(grains.sublayers?.count == 1 && grains.sublayers?.first?.contents != nil)
    #expect(content.sublayers?.last === renderer.layer(for: "child"))
}

/// An 8 × 8 PNG: a black 4 × 4 square at the top left, white elsewhere.
private func checker() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    context.setFillColor(.black)
    // Bottom-left origin: the top-left quarter starts at y = 4.
    context.fill(CGRect(x: 0, y: 4, width: 4, height: 4))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test @MainActor func textureRepeatsItsImageFromTheTopLeftCorner() throws {
    // 8 pt tiles, one image pixel per point: black in each tile's top-left 4 pt square.
    let image = try snapshot(stage(card([DesignEffect(type: .texture, size: 8, texture: try checker())])))
    for (x, y) in [(42, 42), (50, 42), (42, 50), (106, 90)] { #expect(pixel(image, x, y)[0] < 20, "(\(x), \(y))") }
    for (x, y) in [(46, 42), (42, 46), (54, 54)] { #expect(pixel(image, x, y)[0] > 235, "(\(x), \(y))") }
}

@Test @MainActor func textureOpacityAndBlendApplyAgainstTheFill() throws {
    // Half-transparent black over the red fill gives dark red.
    let faded = try snapshot(stage(card([DesignEffect(type: .texture, size: 8, texture: try checker(), opacity: 0.5)])))
    #expect(abs(pixel(faded, 42, 42)[0] - 128) < 6 && pixel(faded, 42, 42)[1] < 6)
    // Multiplied, white leaves the red fill as it is and black turns it black.
    let multiplied = try snapshot(stage(card([DesignEffect(type: .texture, size: 8, texture: try checker(), blend: .multiply)])))
    #expect(pixel(multiplied, 46, 42)[0] > 245 && pixel(multiplied, 46, 42)[1] < 10)
    #expect(pixel(multiplied, 42, 42)[0] < 10)
}

@Test @MainActor func smallTexturesRepeatAsFewLargeBlocks() throws {
    let renderer = DesignRenderer()
    var frame = DesignNode(id: "f", type: .frame, width: 1000, height: 600)
    frame.effects = [DesignEffect(type: .texture, size: 4, texture: try checker())]
    renderer.sync([frame])
    let tiles = try #require(renderer.contentLayer(for: "f")?.sublayers?.first)
    // 4 pt tiles in 256 pt blocks: 4 × 3 blocks rather than 250 × 150 tiles.
    #expect(tiles.sublayers?.count == 12)
}

@Test @MainActor func textureBlendWorksOnAnEllipseClippedByItsMask() throws {
    // An ellipse clips with a mask rather than masksToBounds; the blend must still apply against its fill.
    var round = card([DesignEffect(type: .texture, size: 8, texture: try checker(), blend: .multiply)], type: .ellipse)
    round.width = 60
    round.height = 60
    let image = try snapshot(stage(round))
    // Near the center: 26 pt into the ellipse on both axes is in a tile's black square (24–28), multiplied to black; 30 pt
    // across is in the tile's white part, which leaves the red fill as it is. The bounding box's corner stays untouched.
    #expect(pixel(image, 66, 66)[0] < 10)
    #expect(pixel(image, 70, 66)[0] > 245 && pixel(image, 70, 66)[1] < 10)
    #expect(pixel(image, 41, 41) == [255, 255, 255, 255])
}
