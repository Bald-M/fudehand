import AppKit
import Foundation
import Metal
import QuartzCore
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Panning and zooming the canvas (#241): top-level layers far outside the view are not composited, and while the view moves a
/// top-level frame with effects is shown as a bitmap of itself instead of its live layers.
enum CanvasBitmapFixture {
    /// A frame holding a fill and a glass card over it, and a frame without effects to its right.
    static func document() -> DesignDocument {
        var glassFrame = DesignNode(id: "g", type: .frame, name: "Glass", width: 300, height: 200)
        glassFrame.fill = .white
        var spot = DesignNode(id: "spot", type: .ellipse, x: 40, y: 40, width: 120, height: 120)
        spot.fill = DesignColor(r: 1, g: 0.5, b: 0, a: 1)
        var card = DesignNode(id: "card", type: .rectangle, x: 20, y: 80, width: 260, height: 80)
        card.effects = [DesignEffect(type: .glass)]
        glassFrame.children = [spot, card]
        var plain = DesignNode(id: "plain", type: .frame, name: "Plain", x: 400, width: 300, height: 200)
        plain.fill = .white
        return DesignDocument(nodes: [glassFrame, plain])
    }

    /// Composites `content` (a renderer's root, in world coordinates) offscreen at `viewport` over a canvas of `size` points,
    /// at 2 pixels per point, and returns the pixels (BGRA). The root is moved onto a stage of its own and put back after:
    /// a layer can be drawn by one renderer only.
    @MainActor static func composite(_ content: CALayer, _ viewport: Viewport, size: CGSize) throws -> [UInt8] {
        let home = content.superlayer
        content.removeFromSuperlayer()
        defer { home?.addSublayer(content) }
        let stage = CALayer()
        stage.isGeometryFlipped = true
        stage.backgroundColor = CGColor(gray: 0.5, alpha: 1)
        stage.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        // As snapshots do: a transform on the layer holding the world, not a sublayer transform, which the offscreen renderer
        // draws background filters, glass tints, and shadows under incorrectly.
        let world = CALayer()
        world.anchorPoint = .zero
        world.bounds = CGRect(origin: .zero, size: size)
        world.position = CGPoint(x: viewport.x * 2, y: viewport.y * 2)
        world.transform = CATransform3DMakeScale(2 * viewport.scale, 2 * viewport.scale, 1)
        stage.addSublayer(world)
        world.addSublayer(content)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let width = Int(stage.bounds.width), height = Int(stage.bounds.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let compositor = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                 kCARendererMetalCommandQueue: queue])
        compositor.layer = stage
        compositor.bounds = stage.bounds
        CATransaction.flush()
        compositor.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        compositor.addUpdate(compositor.bounds)
        compositor.render()
        compositor.endFrame()
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    /// The share of pixels whose channels differ by more than 8 / 255.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var differing = 0
        for pixel in stride(from: 0, to: min(a.count, b.count), by: 4)
        where (0..<3).contains(where: { abs(Int(a[pixel + $0]) - Int(b[pixel + $0])) > 8 }) { differing += 1 }
        return Double(differing) / Double(a.count / 4)
    }

    /// Lets the canvas's queued main-thread work (drawing bitmaps) run until `done` holds, for up to 5 s.
    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<250 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }
}

@MainActor private func onCanvas(_ h: CanvasHarness, _ id: String) -> Bool {
    guard let layer = h.canvas.renderer.layer(for: id) else { return false }
    return h.canvas.renderer.root.sublayers?.contains { $0 === layer } ?? false
}

@MainActor private func standInOnCanvas(_ h: CanvasHarness, _ id: String) -> Bool {
    guard let layer = h.canvas.bitmaps.layer(for: id) else { return false }
    return h.canvas.renderer.root.sublayers?.contains { $0 === layer } ?? false
}

@Test @MainActor func topLevelLayersFarOutsideTheViewAreLeftOut() {
    var document = CanvasBitmapFixture.document()
    document.nodes[1].x = 20_000
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    #expect(onCanvas(h, "g"))
    #expect(!onCanvas(h, "plain"))

    h.canvas.setLiveViewport(Viewport(x: -19_900, y: 100, scale: 1), zooming: false)
    #expect(onCanvas(h, "plain"))
    #expect(!onCanvas(h, "g"))
}

@Test @MainActor func zoomingOutBringsLeftOutLayersBack() {
    var document = CanvasBitmapFixture.document()
    document.nodes[1].x = 6_000
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    #expect(!onCanvas(h, "plain"))
    // A pending zoom is a transform of the committed world; the live viewport decides what must be there.
    h.canvas.setLiveViewport(Viewport(x: 0, y: 100, scale: 0.1), zooming: true)
    #expect(onCanvas(h, "plain"))
}

@Test @MainActor func frameWithEffectsIsShownAsItsBitmapOnceDrawn() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    // Live until its bitmap is drawn, then the bitmap, at rest (#245) as while the view moves (#241).
    #expect(onCanvas(h, "g"))
    try await CanvasBitmapFixture.wait { standInOnCanvas(h, "g") }
    #expect(standInOnCanvas(h, "g"))
    #expect(!onCanvas(h, "g"))

    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 1), zooming: false)
    #expect(standInOnCanvas(h, "g"))
    h.canvas.settleViewport()
    #expect(standInOnCanvas(h, "g"))
}

@Test @MainActor func editedFrameAtRestIsShownLiveUntilItsBitmapIsRedrawn() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { standInOnCanvas(h, "g") }
    // A drag shows its result at once, on the live layers.
    h.store.canvasBeginGesture("Move Layers")
    h.store.canvasMove(["spot": Point(x: 60, y: 40)])
    #expect(onCanvas(h, "g"))
    h.store.canvasMove(["spot": Point(x: 70, y: 40)])
    h.store.canvasEndGesture()
    #expect(onCanvas(h, "g"))
    try await CanvasBitmapFixture.wait { standInOnCanvas(h, "g") }
    #expect(standInOnCanvas(h, "g"))
}

@Test @MainActor func atRestABitmapTooCoarseForTheZoomIsNotShown() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { standInOnCanvas(h, "g") }
    // Zoomed in: the old bitmap would look soft at rest, so the live layers show until it is drawn again.
    h.canvas.inputPause = 3600
    h.canvas.noteInput()
    h.canvas.setLiveViewport(Viewport(x: 0, y: 100, scale: 3), zooming: true)
    #expect(standInOnCanvas(h, "g"))
    h.canvas.settleViewport()
    #expect(onCanvas(h, "g"))
    h.canvas.inputPause = 0
    h.canvas.scheduleBitmaps(restart: true)
    try await CanvasBitmapFixture.wait { standInOnCanvas(h, "g") }
    // Zoomed back out: the sharper bitmap serves at once.
    h.canvas.setLiveViewport(Viewport(x: 0, y: 100, scale: 1), zooming: true)
    h.canvas.settleViewport()
    #expect(standInOnCanvas(h, "g"))
}

@Test @MainActor func frameWithoutEffectsStaysLiveWhileTheViewMoves() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 1), zooming: false)
    #expect(h.canvas.bitmaps.layer(for: "plain") == nil)
    #expect(onCanvas(h, "plain"))
}

@Test @MainActor func editedFrameIsShownLiveUntilItsBitmapIsRedrawn() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 1), zooming: false)
    #expect(standInOnCanvas(h, "g"))

    h.store.canvasBeginGesture("Move Layers")
    h.store.canvasMove(["spot": Point(x: 60, y: 40)])
    h.store.canvasEndGesture()
    #expect(onCanvas(h, "g"))
    #expect(!standInOnCanvas(h, "g"))

    // The bitmap is drawn again in the background and takes over while the view is still moving.
    try await CanvasBitmapFixture.wait { standInOnCanvas(h, "g") }
    #expect(standInOnCanvas(h, "g"))
}

@Test @MainActor func bitmapCoversTheFrameAtTheCanvasRasterScale() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    let standIn = try #require(h.canvas.bitmaps.layer(for: "g"))
    #expect(standIn.frame.contains(CGRect(x: 0, y: 0, width: 300, height: 200)))
    let image = try #require(standIn.contents.map { $0 as! CGImage })
    #expect(CGFloat(image.width) == (standIn.frame.width * h.canvas.renderer.contentsScale).rounded(.up))
}

@Test @MainActor func bitmapIsDrawnAgainAtTheNewZoom() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    let before = h.canvas.bitmaps.layer(for: "g")?.contents.map { ($0 as! CGImage).width }
    h.canvas.setLiveViewport(Viewport(x: 0, y: 100, scale: 3), zooming: true)
    h.canvas.settleViewport()
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g")?.contents.map { ($0 as! CGImage).width } != before }
    let after = h.canvas.bitmaps.layer(for: "g")?.contents.map { ($0 as! CGImage).width }
    #expect(after != nil && after! > before!)
}

@Test @MainActor func bitmapShowsWhatTheSnapshotShows() async throws {
    let document = CanvasBitmapFixture.document()
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    let standIn = try #require(h.canvas.bitmaps.layer(for: "g"))
    let bitmap = try #require(standIn.contents.map { $0 as! CGImage })
    let scale = h.canvas.renderer.contentsScale
    let snapshot = try #require(NSBitmapImageRep(data: try DesignRenderer.snapshotPNG(document.nodes[0], scale: scale)))
    let drawn = NSBitmapImageRep(cgImage: bitmap)
    // The frame's top-left corner sits where its paint bounds start in the bitmap; the glass card and the spot under it
    // are sampled at a few points.
    let inset = (x: Int((-standIn.frame.minX * scale).rounded()), y: Int((-standIn.frame.minY * scale).rounded()))
    for point in [(30, 30), (100, 100), (150, 120), (250, 150), (290, 190)] {
        let x = Int(Double(point.0) * scale), y = Int(Double(point.1) * scale)
        let expected = try #require(snapshot.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let actual = try #require(drawn.colorAt(x: x + inset.x, y: y + inset.y)?.usingColorSpace(.sRGB))
        #expect(abs(expected.redComponent - actual.redComponent) < 0.02 && abs(expected.greenComponent - actual.greenComponent) < 0.02
                && abs(expected.blueComponent - actual.blueComponent) < 0.02, "at \(point)")
    }
}


@Test @MainActor func bitmapLinesUpWithTheLiveLayers() async throws {
    // A glass card with a drop shadow over a stripe, under a blurred glow. The frame and the view sit on whole pixels: elsewhere
    // the bitmap is resampled, which softens its edges a little.
    var frame = DesignNode(id: "frame", type: .frame, name: "Frame", x: 10.5, y: 20.25, width: 300, height: 200)
    frame.fill = DesignColor(r: 1, g: 0.5, b: 0, a: 1)
    frame.clipsContent = false
    var stripe = DesignNode(id: "stripe", type: .rectangle, x: 0, y: 90, width: 300, height: 20)
    stripe.fill = DesignColor(r: 0, g: 0, b: 1, a: 1)
    var card = DesignNode(id: "card", type: .rectangle, x: 40, y: 60, width: 200, height: 80)
    card.cornerRadius = 16
    card.effects = [DesignEffect(type: .dropShadow, radius: 12), DesignEffect(type: .glass)]
    var glow = DesignNode(id: "glow", type: .ellipse, x: 250, y: -20, width: 80, height: 80)
    glow.fill = DesignColor(r: 0.2, g: 0.8, b: 0.3, a: 1)
    glow.effects = [DesignEffect(type: .layerBlur, radius: 20)]
    frame.children = [stripe, card, glow]
    let h = CanvasHarness(document: DesignDocument(nodes: [frame]))
    defer { h.dispose() }
    let viewport = Viewport(x: 37, y: 61.5, scale: 1)
    h.request(viewport)
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "frame")?.contents != nil }
    let standIn = try #require(h.canvas.bitmaps.layer(for: "frame"))
    // The bitmap where the canvas puts it, against the frame's live layers from a renderer of its own. (One frame at a time:
    // Core Animation's offscreen renderer drops glass tints and shadows when several top-level layers share a root, although
    // the window server draws them; the App was checked by eye in light and dark.)
    let holder = CALayer()
    holder.addSublayer(standIn)
    let moving = try CanvasBitmapFixture.composite(holder, viewport, size: h.canvas.bounds.size)
    let live = DesignRenderer()
    live.contentsScale = h.canvas.renderer.contentsScale
    live.sync([frame])
    let settled = try CanvasBitmapFixture.composite(live.root, viewport, size: h.canvas.bounds.size)
    // Measured: about 480 of the 2.8 million pixels differ (soft blur edges); a bitmap half a point out of place makes about 1800.
    #expect(CanvasBitmapFixture.difference(settled, moving) * Double(settled.count / 4) < 1000)
}

@Test @MainActor func importedFontsDropTheBitmaps() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    h.canvas.fontsChanged()
    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 1), zooming: false)
    #expect(onCanvas(h, "g"))
    #expect(!standInOnCanvas(h, "g"))
}

@Test @MainActor func layerWhoseShadowAloneReachesIntoTheViewIsKept() {
    var document = CanvasBitmapFixture.document()
    // The frame ends 20 points left of the view; its shadow reaches 2 × 30 points past it.
    document.nodes[1].x = -320
    document.nodes[1].effects = [DesignEffect(type: .dropShadow, x: 0, y: 0, radius: 30)]
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    #expect(onCanvas(h, "plain"))
    document.nodes[1].effects = []
    h.store.replace(document, url: nil)
    #expect(!onCanvas(h, "plain"))
}

@Test @MainActor func deletingALayerWhileTheViewMovesRemovesIt() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 1), zooming: false)
    #expect(standInOnCanvas(h, "g"))
    var document = CanvasBitmapFixture.document()
    document.nodes.removeFirst()
    h.store.replace(document, url: nil)
    #expect(!standInOnCanvas(h, "g"))
    #expect(h.canvas.renderer.layer(for: "g") == nil)
    #expect(h.canvas.renderer.root.sublayers?.count == 1)
}

@Test @MainActor func bitmapFromTheLastZoomIsShownUntilTheViewSettles() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g")?.contents != nil }
    let before = try #require(h.canvas.bitmaps.layer(for: "g")?.contents.map { ($0 as! CGImage).width })
    // Zoom in and pan straight away: the old bitmap stands in, stretched, and is not drawn again while the view moves.
    h.canvas.setLiveViewport(Viewport(x: 0, y: 100, scale: 3), zooming: true)
    h.canvas.settleViewport()
    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 3), zooming: false)
    #expect(standInOnCanvas(h, "g"))
    try await Task.sleep(for: .milliseconds(500))
    #expect(h.canvas.bitmaps.layer(for: "g")?.contents.map { ($0 as! CGImage).width } == before)
    h.canvas.settleViewport()
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g")?.contents.map { ($0 as! CGImage).width } != before }
    #expect((h.canvas.bitmaps.layer(for: "g")?.contents.map { ($0 as! CGImage).width } ?? 0) > before)
}

@Test @MainActor func paintBoundsFollowANodeBackToTheTopLevel() {
    let renderer = DesignRenderer()
    renderer.visibleRect = CGRect(x: 110, y: 0, width: 100, height: 100)
    var card = DesignNode(id: "card", type: .rectangle, width: 100, height: 100)
    var holder = DesignNode(id: "holder", type: .frame, x: 500, width: 200, height: 200)
    renderer.sync([card])
    #expect((renderer.root.sublayers ?? []).isEmpty)
    // Nested, it gains a shadow reaching 2 × 20 points; back at the top level, unchanged since, the shadow reaches the view.
    card.effects = [DesignEffect(type: .dropShadow, x: 0, y: 0, radius: 20)]
    holder.children = [card]
    renderer.sync([holder])
    renderer.sync([card])
    #expect(renderer.root.sublayers?.contains { $0 === renderer.layer(for: "card") } == true)
}

// #243: drawing bitmaps must not hold up the main thread, pauses while the person works, and keeps to a memory budget.

@Test @MainActor func bitmapIsFinishedOffTheMainThread() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    let bitmaps = CanvasBitmaps()
    let near = CGRect(x: -100, y: -100, width: 1200, height: 900)
    var finished = false
    let started = bitmaps.drawNext(h.canvas.document.nodes, near: near, scale: 2) { finished = true }
    // Started, but the pixels arrive in a later main-thread turn: rendering and reading back wait for the GPU elsewhere.
    #expect(started != nil)
    #expect(bitmaps.drawing)
    #expect(bitmaps.layer(for: "g")?.contents == nil)
    try await CanvasBitmapFixture.wait { finished }
    #expect(!bitmaps.drawing)
    let image = try #require(bitmaps.layer(for: "g")?.contents.map { $0 as! CGImage })
    // The same pixels as drawing it in one go.
    let paint = try #require(CanvasBitmapFixture.document().nodes[0].paintBounds)
    let direct = try DesignRenderer.image(of: CanvasBitmapFixture.document().nodes[0],
                                          in: CGRect(x: paint.x, y: paint.y, width: paint.width, height: paint.height), scale: 2)
    #expect(image.width == direct.width && image.height == direct.height)
    #expect(image.dataProvider?.data as Data? == direct.dataProvider?.data as Data?)
}

@Test @MainActor func onlyOneBitmapIsDrawnAtATime() async throws {
    var document = CanvasBitmapFixture.document()
    var second = document.nodes[0]
    second.id = "g2"
    second.x = 400
    second.children = second.children.map { var child = $0; child.id += "2"; return child }
    document.nodes = [document.nodes[0], second]
    let bitmaps = CanvasBitmaps()
    let near = CGRect(x: -100, y: -100, width: 1200, height: 900)
    var finished = 0
    #expect(bitmaps.drawNext(document.nodes, near: near, scale: 2) { finished += 1 } != nil)
    #expect(bitmaps.drawNext(document.nodes, near: near, scale: 2) { finished += 1 } == nil)
    try await CanvasBitmapFixture.wait { finished == 1 }
    #expect(bitmaps.drawNext(document.nodes, near: near, scale: 2) { finished += 1 } != nil)
    try await CanvasBitmapFixture.wait { finished == 2 }
    #expect(bitmaps.current(document.nodes).count == 2)
}

@Test @MainActor func bitmapsKeepToTheirPixelBudgetNearestFirst() async throws {
    var document = CanvasBitmapFixture.document()
    var second = document.nodes[0]
    second.id = "g2"
    second.x = 400
    second.children = second.children.map { var child = $0; child.id += "2"; return child }
    document.nodes = [document.nodes[0], second]
    let bitmaps = CanvasBitmaps()
    // Room for one 600 × 400 bitmap (300 × 200 points at 2 pixels per point).
    bitmaps.pixelBudget = 300_000
    // The middle of `near` is nearer the second frame.
    let near = CGRect(x: 0, y: -250, width: 1100, height: 700)
    for _ in 0..<3 {
        guard bitmaps.drawNext(document.nodes, near: near, scale: 2, finished: {}) != nil else { break }
        try await CanvasBitmapFixture.wait { !bitmaps.drawing }
    }
    #expect(bitmaps.current(document.nodes).keys.sorted() == ["g2"])
    #expect(bitmaps.pixelCount <= 300_000)
}

@Test @MainActor func inputPausesDrawingBitmaps() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    // Input just now, and a pause longer than the test: nothing is drawn meanwhile.
    h.canvas.inputPause = 3600
    h.canvas.noteInput()
    try await Task.sleep(for: .milliseconds(600))
    #expect(h.canvas.bitmaps.layer(for: "g")?.contents == nil)
    // Once input has paused long enough, the bitmaps are drawn.
    h.canvas.inputPause = 0
    h.canvas.scheduleBitmaps(restart: true)
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g")?.contents != nil }
    #expect(h.canvas.bitmaps.layer(for: "g")?.contents != nil)
}

@Test @MainActor func missingBitmapsAreDrawnWhileThePersonPans() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    // A pan that keeps going: input every turn, the view moving. A layer with no bitmap at all still gets one, since it is
    // composited live until then.
    h.canvas.inputPause = 3600
    h.canvas.noteInput()
    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 1), zooming: false)
    try await CanvasBitmapFixture.wait { standInOnCanvas(h, "g") }
    #expect(standInOnCanvas(h, "g"))
}

@Test @MainActor func bitmapsFarthestFromTheViewAreDroppedForNearerOnes() async throws {
    var document = CanvasBitmapFixture.document()
    var second = document.nodes[0]
    second.id = "g2"
    second.x = 400
    second.children = second.children.map { var child = $0; child.id += "2"; return child }
    document.nodes = [document.nodes[0], second]
    let bitmaps = CanvasBitmaps()
    bitmaps.pixelBudget = 300_000
    // First around the first frame, then the view moves to the second (both still near): the second replaces the first.
    #expect(bitmaps.drawNext(document.nodes, near: CGRect(x: -300, y: -250, width: 900, height: 700), scale: 2, finished: {}) != nil)
    try await CanvasBitmapFixture.wait { !bitmaps.drawing }
    #expect(bitmaps.current(document.nodes).keys.sorted() == ["g"])
    bitmaps.pixelBudget = 300_000
    let later = CGRect(x: 150, y: -250, width: 1000, height: 700)
    // g is still near but farther than g2 now; g2 does not fit beside it, and nearer bitmaps come first.
    if bitmaps.drawNext(document.nodes, near: later, scale: 2, finished: {}) != nil {
        try await CanvasBitmapFixture.wait { !bitmaps.drawing }
    }
    #expect(bitmaps.current(document.nodes).keys.sorted() == ["g2"])
    #expect(bitmaps.pixelCount <= 300_000)
}

@Test @MainActor func nodeEditedWhileItsBitmapIsDrawnIsNotShownAsItWas() async throws {
    let document = CanvasBitmapFixture.document()
    let bitmaps = CanvasBitmaps()
    let near = CGRect(x: -100, y: -100, width: 1200, height: 900)
    #expect(bitmaps.drawNext(document.nodes, near: near, scale: 2, finished: {}) != nil)
    var edited = document
    edited.nodes[0].children[0].x += 30
    try await CanvasBitmapFixture.wait { !bitmaps.drawing }
    #expect(bitmaps.current(document.nodes)["g"] != nil)
    #expect(bitmaps.current(edited.nodes)["g"] == nil)
}

@Test @MainActor func bitmapDrawnAcrossAFontChangeIsDropped() async throws {
    let document = CanvasBitmapFixture.document()
    let bitmaps = CanvasBitmaps()
    let near = CGRect(x: -100, y: -100, width: 1200, height: 900)
    var finished = false
    #expect(bitmaps.drawNext(document.nodes, near: near, scale: 2) { finished = true } != nil)
    bitmaps.removeAll()
    try await CanvasBitmapFixture.wait { finished }
    #expect(!bitmaps.drawing)
    #expect(bitmaps.current(document.nodes).isEmpty)
}
