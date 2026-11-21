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

/// A white stage with a red square at (40, 40), 60 × 60, and a see-through glass card over it at (70, 40), 80 × 60.
private func glassStage(_ glass: DesignEffect) -> DesignNode {
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 160)
    frame.fill = .white
    var red = DesignNode(id: "red", type: .rectangle, x: 40, y: 40, width: 60, height: 60)
    red.fill = DesignColor(r: 1, g: 0, b: 0)
    var pane = DesignNode(id: "pane", type: .rectangle, x: 70, y: 40, width: 80, height: 60)
    pane.effects = [glass]
    frame.children = [red, pane]
    return frame
}

@Test @MainActor func glassTintsWhatIsUnderIt() throws {
    let image = try snapshot(glassStage(DesignEffect(type: .glass, radius: 0, saturation: 1, highlight: 0)))
    // White at 20% over red, inside the pane; red untouched outside it; white stays white under the pane.
    let tinted = pixel(image, 85, 70)
    #expect(tinted[0] > 250 && abs(tinted[1] - 51) < 6 && abs(tinted[2] - 51) < 6, "\(tinted)")
    #expect(pixel(image, 55, 70) == [255, 0, 0, 255])
    #expect(pixel(image, 130, 70) == [255, 255, 255, 255])
}

@Test @MainActor func glassSaturationAndHighlight() throws {
    // Saturation 0 turns the red under the pane grey; it does not reach the red outside.
    let grey = try snapshot(glassStage(DesignEffect(type: .glass, color: DesignColor(r: 1, g: 1, b: 1, a: 0), radius: 0, saturation: 0, highlight: 0)))
    let under = pixel(grey, 85, 70)
    #expect(abs(under[0] - under[1]) < 6 && abs(under[1] - under[2]) < 6 && under[0] < 230, "\(under)")
    #expect(pixel(grey, 55, 70) == [255, 0, 0, 255])
    // The highlight lightens the pane's top inner edge over the red, and not the middle of its left edge.
    let lit = try snapshot(glassStage(DesignEffect(type: .glass, color: DesignColor(r: 1, g: 1, b: 1, a: 0), radius: 0, saturation: 1, highlight: 1)))
    #expect(pixel(lit, 85, 40)[1] > 200, "\(pixel(lit, 85, 40))")
    #expect(pixel(lit, 70, 95)[1] < 20, "\(pixel(lit, 70, 95))")
}

/// A white 200 × 160 frame seen with `perspective`, holding an 80 × 80 red card at (60, 40) turned by `turn`.
private func turnedStage(_ turn: DesignEffect, perspective: DesignEffect? = DesignEffect(type: .perspective, distance: 300)) -> DesignNode {
    var frame = DesignNode(id: "f", type: .frame, width: 200, height: 160)
    frame.fill = .white
    if let perspective { frame.effects = [perspective] }
    var card = DesignNode(id: "c", type: .rectangle, x: 60, y: 40, width: 80, height: 80)
    card.fill = DesignColor(r: 1, g: 0, b: 0)
    card.effects = [turn]
    frame.children = [card]
    return frame
}

/// How many red pixels a column (or a row) has.
private func redRun(_ image: NSBitmapImageRep, column: Int? = nil, row: Int? = nil) -> Int {
    if let column { return (0..<image.pixelsHigh).filter { pixel(image, column, $0)[1] < 100 && pixel(image, column, $0)[0] > 150 }.count }
    return (0..<image.pixelsWide).filter { pixel(image, $0, row!)[1] < 100 && pixel(image, $0, row!)[0] > 150 }.count
}

/// The first and last columns with any red.
private func redSpan(_ image: NSBitmapImageRep) -> (Int, Int) {
    let columns = (0..<image.pixelsWide).filter { redRun(image, column: $0) > 0 }
    return (columns.first ?? -1, columns.last ?? -1)
}

@Test @MainActor func rotateYTurnsTheRightEdgeAwayInPerspective() throws {
    let image = try snapshot(turnedStage(DesignEffect(type: .transform3D, rotateY: 40)))
    let (left, right) = redSpan(image)
    // Narrower than 80 pt, and the receding right edge is shorter than the near left edge.
    #expect(right - left < 70)
    #expect(redRun(image, column: right - 1) < redRun(image, column: left + 1) - 6, "left \(redRun(image, column: left + 1)) right \(redRun(image, column: right - 1))")
}

@Test @MainActor func rotateXTipsTheTopEdgeAwayInPerspective() throws {
    let image = try snapshot(turnedStage(DesignEffect(type: .transform3D, rotateX: 40)))
    let rows = (0..<image.pixelsHigh).filter { redRun(image, row: $0) > 0 }
    let top = try #require(rows.first), bottom = try #require(rows.last)
    #expect(redRun(image, row: top + 1) < redRun(image, row: bottom - 1) - 6, "top \(redRun(image, row: top + 1)) bottom \(redRun(image, row: bottom - 1))")
}

@Test @MainActor func translateZBringsTheLayerCloserAndPerspectiveIsNeededForDepth() throws {
    let near = try snapshot(turnedStage(DesignEffect(type: .transform3D, translateZ: 100)))
    #expect(redRun(near, row: 80) > 90)
    // Without a perspective on the frame the projection is flat: depth changes nothing, and a turn narrows evenly.
    let flat = try snapshot(turnedStage(DesignEffect(type: .transform3D, translateZ: 100), perspective: nil))
    #expect(abs(redRun(flat, row: 80) - 80) <= 1)
    let narrowed = try snapshot(turnedStage(DesignEffect(type: .transform3D, rotateY: 60), perspective: nil))
    let (left, right) = redSpan(narrowed)
    #expect(abs((right - left + 1) - 40) <= 2)
    #expect(abs(redRun(narrowed, column: left + 1) - redRun(narrowed, column: right - 1)) <= 1)
}

@Test @MainActor func turningMovesTheLayersBackgroundBlurWithIt() throws {
    let renderer = DesignRenderer()
    var node = DesignNode(id: "c", type: .rectangle, width: 80, height: 80)
    node.effects = [DesignEffect(type: .backgroundBlur), DesignEffect(type: .transform3D, rotateY: 30)]
    renderer.sync([node])
    let layer = try #require(renderer.layer(for: "c"))
    #expect(!CATransform3DIsIdentity(layer.transform))
    #expect(renderer.backdrops(for: "c").allSatisfy { CATransform3DEqualToTransform($0.transform, layer.transform) })
    node.effects = [DesignEffect(type: .backgroundBlur)]
    renderer.sync([node])
    #expect(CATransform3DIsIdentity(try #require(renderer.layer(for: "c")).transform))
}

@Test @MainActor func perspectiveOriginMovesThePointDepthGrowsFrom() throws {
    // Brought 100 pt closer and seen from 300 pt, the card grows by half. Seen from the frame's center it grows evenly about
    // x = 100; seen from the frame's left edge it grows away from x = 0, so its left edge moves right to about 90.
    let centered = try snapshot(turnedStage(DesignEffect(type: .transform3D, translateZ: 100)))
    let fromLeft = try snapshot(turnedStage(DesignEffect(type: .transform3D, translateZ: 100),
                                            perspective: DesignEffect(type: .perspective, distance: 300, originX: 0)))
    #expect(abs(redSpan(centered).0 - 40) <= 3, "\(redSpan(centered))")
    #expect(abs(redSpan(fromLeft).0 - 90) <= 3, "\(redSpan(fromLeft))")
}

@Test @MainActor func removingPerspectiveResetsTheFramesChildren() throws {
    let renderer = DesignRenderer()
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    frame.effects = [DesignEffect(type: .perspective), DesignEffect(type: .layerBlur)]
    renderer.sync([frame])
    let content = try #require(renderer.contentLayer(for: "f"))
    #expect(content.sublayerTransform.m34 != 0)
    frame.effects = [DesignEffect(type: .layerBlur)]
    renderer.sync([frame])
    #expect(CATransform3DIsIdentity(content.sublayerTransform))
    frame.effects = [DesignEffect(type: .perspective, visible: false)]
    renderer.sync([frame])
    #expect(CATransform3DIsIdentity(content.sublayerTransform))
}

private func shaded(_ id: String, _ params: [String: ShaderValue] = [:], opacity: Double = 1) -> DesignEffect {
    var effect = DesignEffect(type: .shader, opacity: opacity)
    effect.shader = id
    effect.shaderParams = ShaderCatalog.entry(id)!.defaults.merging(params) { $1 }
    return effect
}

@Test @MainActor func meshGradientShowsItsCornerColorsAtTheCorners() throws {
    let red = DesignColor(r: 1, g: 0, b: 0), green = DesignColor(r: 0, g: 1, b: 0), blue = DesignColor(r: 0, g: 0, b: 1)
    let image = try snapshot(stage(card([shaded("mesh-gradient", ["topLeft": .color(red), "topRight": .color(green),
                                                                  "bottomLeft": .color(blue), "bottomRight": .color(.white)])])))
    // The card spans (40, 40)–(120, 100); one point in from each corner.
    let topLeft = pixel(image, 41, 41), topRight = pixel(image, 118, 41), bottomLeft = pixel(image, 41, 98)
    #expect(topLeft[0] > 240 && topLeft[1] < 20 && topLeft[2] < 20, "\(topLeft)")
    #expect(topRight[1] > 240 && topRight[0] < 20, "\(topRight)")
    #expect(bottomLeft[2] > 240 && bottomLeft[0] < 20, "\(bottomLeft)")
    #expect(pixel(image, 118, 98).allSatisfy { $0 > 240 })
}

@Test @MainActor func halftoneDotsGrowAcrossTheLayer() throws {
    let image = try snapshot(stage(card([shaded("halftone", ["color": .color(DesignColor(r: 0, g: 0, b: 1)), "angle": .number(0)])])), scale: 2)
    // Share of blue pixels in the card's left and right fifths, on top of its red fill.
    func blue(_ columns: Range<Int>) -> Double {
        let hits = columns.flatMap { x in (80..<200).map { y in pixel(image, x, y) } }.filter { $0[2] > 128 && $0[0] < 128 }.count
        return Double(hits) / Double(columns.count * 120)
    }
    #expect(blue(80..<112) < 0.05)
    #expect(blue(208..<240) > 0.5)
}

@Test @MainActor func wavesBlendItsTwoColorsAndOpacityFadesThem() throws {
    let image = try snapshot(stage(card([shaded("waves", ["colorA": .color(.black), "colorB": .color(.white), "scale": .number(20)])])))
    let row = (40..<120).map { pixel(image, $0, 70)[0] }
    #expect(row.min()! < 40 && row.max()! > 215, "\(row.min()!)–\(row.max()!)")
    // Half-transparent black over the red fill.
    let faded = try snapshot(stage(card([shaded("mesh-gradient", ["topLeft": .color(.black), "topRight": .color(.black), "bottomLeft": .color(.black),
                                                                  "bottomRight": .color(.black)], opacity: 0.5)])))
    #expect(abs(pixel(faded, 80, 70)[0] - 128) < 6)
}

@Test @MainActor func shaderSitsBelowTheChildLayersAndRedrawsWhenZoomed() throws {
    let renderer = DesignRenderer()
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    frame.effects = [shaded("waves")]
    frame.children = [DesignNode(id: "child", type: .rectangle, width: 10, height: 10)]
    renderer.sync([frame])
    let content = try #require(renderer.contentLayer(for: "f"))
    let layer = try #require(content.sublayers?.first as? ShaderLayer)
    #expect(content.sublayers?.last === renderer.layer(for: "child"))
    layer.displayIfNeeded()
    let before = (layer.contents as! CGImage).width
    renderer.contentsScale = 4
    layer.displayIfNeeded()
    #expect((layer.contents as! CGImage).width == before * 2)
}

@Test @MainActor func resizingAShadedLayerStretchesTheOldBitmapUntilTheSizeSettles() async throws {
    let renderer = DesignRenderer()
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    frame.effects = [shaded("waves")]
    renderer.sync([frame])
    let first = try #require(renderer.contentLayer(for: "f")?.sublayers?.first as? ShaderLayer)
    first.displayIfNeeded()
    let rendered = try #require(first.contents)
    // Each resize frame rebuilds the layer; it shows the previous bitmap rather than rendering again.
    frame.width = 140
    renderer.sync([frame])
    let resized = try #require(renderer.contentLayer(for: "f")?.sublayers?.first as? ShaderLayer)
    resized.displayIfNeeded()
    #expect(resized !== first && (resized.contents as AnyObject?) === (rendered as AnyObject))
    // Once the size has not changed for a moment, it renders at the new size.
    try await Task.sleep(for: .milliseconds(400))
    resized.displayIfNeeded()
    #expect((resized.contents as! CGImage).width > (rendered as! CGImage).width)
}
