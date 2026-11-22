import AppKit
import Foundation
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

@Test @MainActor func movingViewShowsBitmapOfFrameWithEffectsUntilItSettles() async throws {
    let h = CanvasHarness(document: CanvasBitmapFixture.document())
    defer { h.dispose() }
    try await CanvasBitmapFixture.wait { h.canvas.bitmaps.layer(for: "g") != nil }
    #expect(h.canvas.bitmaps.layer(for: "g")?.contents != nil)
    #expect(onCanvas(h, "g"))

    h.canvas.setLiveViewport(Viewport(x: -10, y: 90, scale: 1), zooming: false)
    #expect(standInOnCanvas(h, "g"))
    #expect(!onCanvas(h, "g"))

    h.canvas.settleViewport()
    #expect(onCanvas(h, "g"))
    #expect(!standInOnCanvas(h, "g"))
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
