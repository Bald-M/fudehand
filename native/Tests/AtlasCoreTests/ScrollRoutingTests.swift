import Testing
import AtlasCore

@Test func beganLocksTarget() {
    var router = ScrollRouter()
    #expect(router.route(phase: .began, overActivePage: false, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .changed, overActivePage: true, zoomModifier: false) == .canvas)
    #expect(router.locked == .canvas)
}

@Test func momentumKeepsLockedTarget() {
    var router = ScrollRouter()
    _ = router.route(phase: .began, overActivePage: false, zoomModifier: false)
    #expect(router.route(phase: .ended, overActivePage: true, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .momentum, overActivePage: true, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .momentumEnded, overActivePage: true, zoomModifier: false) == .canvas)
    #expect(router.locked == nil)
}

@Test func discreteWheelRoutesPerEvent() {
    var router = ScrollRouter()
    #expect(router.route(phase: .discrete, overActivePage: true, zoomModifier: false) == .page)
    #expect(router.route(phase: .discrete, overActivePage: false, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .discrete, overActivePage: true, zoomModifier: false) == .page)
    #expect(router.locked == nil)
}

@Test func zoomModifierAlwaysCanvas() {
    var router = ScrollRouter()
    _ = router.route(phase: .began, overActivePage: true, zoomModifier: false)
    #expect(router.locked == .page)
    #expect(router.route(phase: .changed, overActivePage: true, zoomModifier: true) == .canvas)
    #expect(router.locked == .page)
}
