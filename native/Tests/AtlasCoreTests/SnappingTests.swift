import Testing
import AtlasCore

@Test func snapsLeftEdgeWithinThreshold() {
    let r = Snapping.snap(Rect(x: 104, y: 300, width: 50, height: 50), to: [Rect(x: 100, y: 0, width: 200, height: 100)], threshold: 6)
    #expect(r.offset == Point(x: -4, y: 0))
    #expect(r.guides == [Guide(axis: .vertical, position: 100, start: 0, end: 350)])
}

@Test func snapsCentersAndPicksNearest() {
    // moving midX = 205, other midX = 200 (distance 5), other maxX = 300 (far)
    let r = Snapping.snap(Rect(x: 180, y: 0, width: 50, height: 10), to: [Rect(x: 100, y: 500, width: 200, height: 10)], threshold: 6)
    #expect(r.offset.x == -5)
}

@Test func noSnapOutsideThreshold() {
    let r = Snapping.snap(Rect(x: 110, y: 0, width: 10, height: 10), to: [Rect(x: 100, y: 500, width: 1, height: 1)], threshold: 6)
    #expect(r.offset == Point(x: 0, y: 0) && r.guides.isEmpty)
}

@Test func snapsBothAxes() {
    let r = Snapping.snap(Rect(x: 2, y: 103, width: 10, height: 10), to: [Rect(x: 0, y: 100, width: 50, height: 50)], threshold: 6)
    #expect(r.offset == Point(x: -2, y: -3))
    #expect(r.guides.count == 2)
}
