import Testing
import AtlasCore

@Test func zoomKeepsThePointUnderThePointerStationary() {
    let view = Viewport(x: 120, y: -40, scale: 0.5)
    let zoomed = CanvasGeometry.zoomAt(view, point: Point(x: 220, y: 160), scale: 1)
    #expect(zoomed == Viewport(x: 20, y: -240, scale: 1))
    #expect(CanvasGeometry.screenToWorld(Point(x: 220, y: 160), viewport: zoomed) == Point(x: 200, y: 400))
}

@Test func frameDraggingAndFitUseCanvasCoordinates() {
    #expect(CanvasGeometry.moveFrame(Point(x: 10, y: 20), screenDelta: Point(x: 100, y: -50), scale: 0.5) == Point(x: 210, y: -80))
    #expect(CanvasGeometry.fitRects([Rect(x: -100, y: -50, width: 200, height: 100)], size: Size(width: 600, height: 400), padding: 64) == Viewport(x: 300, y: 200, scale: 1))
    #expect(CanvasGeometry.fitRects([], size: Size(width: 600, height: 400)) == Viewport())
    #expect(CanvasGeometry.zoomAt(Viewport(), point: Point(x: 0, y: 0), scale: 100).scale == 2)
    #expect(CanvasGeometry.zoomAt(Viewport(), point: Point(x: 0, y: 0), scale: 0).scale == 0.1)
}
