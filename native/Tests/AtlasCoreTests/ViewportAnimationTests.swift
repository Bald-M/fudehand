import Testing
import Foundation
import AtlasCore

@Test func animationEndpointsAreExact() {
    let a = Viewport(x: 10, y: 20, scale: 0.25), b = Viewport(x: -300, y: 40, scale: 1), s = Size(width: 800, height: 600)
    let start = ViewportAnimation.value(from: a, to: b, size: s, fraction: 0)
    let end = ViewportAnimation.value(from: a, to: b, size: s, fraction: 1)
    #expect(abs(start.x - a.x) < 1e-9 && abs(start.y - a.y) < 1e-9 && abs(start.scale - a.scale) < 1e-9)
    #expect(abs(end.x - b.x) < 1e-9 && abs(end.y - b.y) < 1e-9 && abs(end.scale - b.scale) < 1e-9)
}

@Test func scaleInterpolatesInLogSpace() {
    let v = ViewportAnimation.value(from: Viewport(scale: 0.25), to: Viewport(scale: 1), size: Size(width: 800, height: 600), fraction: 0.5)
    #expect(abs(v.scale - 0.5) < 1e-9)
}

@Test func easeOutIsMonotonicAndClamped() {
    #expect(ViewportAnimation.easeOut(-1) == 0 && ViewportAnimation.easeOut(2) == 1)
    let samples = stride(from: 0.0, through: 1.0, by: 0.1).map(ViewportAnimation.easeOut)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 })
    #expect(ViewportAnimation.easeOut(0.5) > 0.5)
}
