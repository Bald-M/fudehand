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
    #expect(CanvasGeometry.zoomAt(Viewport(), point: Point(x: 0, y: 0), scale: 100).scale == 4)
    #expect(CanvasGeometry.zoomAt(Viewport(), point: Point(x: 0, y: 0), scale: 0).scale == 0.05)
}

@Test func lineBasedWheelNotchesMoveTheCanvasOneLineEach() {
    #expect(CanvasGeometry.wheelDelta(Point(x: 1, y: -2), precise: false) == Point(x: 16, y: -32))
    #expect(CanvasGeometry.wheelDelta(Point(x: 3.5, y: -7), precise: true) == Point(x: 3.5, y: -7))
}

@Test func rectHelpers() {
    let a = Rect(x: 0, y: 0, width: 100, height: 50)
    #expect(a.midX == 50 && a.maxY == 50)
    #expect(a.intersects(Rect(x: 99, y: 49, width: 10, height: 10)))
    #expect(!a.intersects(Rect(x: 100, y: 0, width: 10, height: 10)))   // touching only is not intersecting
    #expect(Rect.union([a, Rect(x: -10, y: 20, width: 5, height: 100)]) == Rect(x: -10, y: 0, width: 110, height: 120))
    #expect(Rect.union([]) == nil)
    #expect(Rect.spanning(Point(x: 10, y: 5), Point(x: 0, y: 25)) == Rect(x: 0, y: 5, width: 10, height: 20))
    #expect(a.offsetBy(Point(x: 3, y: -2)) == Rect(x: 3, y: -2, width: 100, height: 50))
}

@Test func pointArithmetic() {
    #expect(Point(x: 1, y: 2) + Point(x: 3, y: 4) == Point(x: 4, y: 6))
    #expect(Point(x: 1, y: 2) - Point(x: 3, y: 4) == Point(x: -2, y: -2))
}

@Test func fitNeverZoomsBeyondActualSize() {
    let tiny = Rect(x: 0, y: 0, width: 10, height: 10)
    #expect(CanvasGeometry.fitRects([tiny], size: Size(width: 800, height: 600)).scale == 1)
}
