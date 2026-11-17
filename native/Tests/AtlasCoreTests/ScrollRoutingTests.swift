import Testing
import AtlasCore

@Test func plainScrollOverActivePageIsCanvas() {
    var router = ScrollRouter()
    #expect(router.route(phase: .began, overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .changed, overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .discrete, overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
}

@Test func beganLocksTarget() {
    var router = ScrollRouter()
    #expect(router.route(phase: .began, overActivePage: false, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .changed, overActivePage: true, pageModifier: true, zoomModifier: false) == .canvas)
    #expect(router.locked == .canvas)
}

@Test func optionPressedMidGestureKeepsCanvas() {
    var router = ScrollRouter()
    _ = router.route(phase: .began, overActivePage: true, pageModifier: false, zoomModifier: false)
    #expect(router.route(phase: .changed, overActivePage: true, pageModifier: true, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .momentum, overActivePage: true, pageModifier: true, zoomModifier: false) == .canvas)
}

@Test func optionReleasedMidGestureKeepsPage() {
    var router = ScrollRouter()
    #expect(router.route(phase: .began, overActivePage: true, pageModifier: true, zoomModifier: false) == .page)
    #expect(router.route(phase: .changed, overActivePage: true, pageModifier: false, zoomModifier: false) == .page)
    #expect(router.route(phase: .ended, overActivePage: false, pageModifier: false, zoomModifier: false) == .page)
    #expect(router.route(phase: .momentum, overActivePage: false, pageModifier: false, zoomModifier: false) == .page)
    #expect(router.route(phase: .momentumEnded, overActivePage: false, pageModifier: false, zoomModifier: false) == .page)
    #expect(router.locked == nil)
}

@Test func optionOutsideActivePageIsCanvas() {
    var router = ScrollRouter()
    #expect(router.route(phase: .began, overActivePage: false, pageModifier: true, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .discrete, overActivePage: false, pageModifier: true, zoomModifier: false) == .canvas)
}

@Test func momentumKeepsLockedTarget() {
    var router = ScrollRouter()
    _ = router.route(phase: .began, overActivePage: false, pageModifier: false, zoomModifier: false)
    #expect(router.route(phase: .ended, overActivePage: true, pageModifier: true, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .momentum, overActivePage: true, pageModifier: true, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .momentumEnded, overActivePage: true, pageModifier: true, zoomModifier: false) == .canvas)
    #expect(router.locked == nil)
}

@Test func discreteWheelRoutesPerEvent() {
    var router = ScrollRouter()
    #expect(router.route(phase: .discrete, overActivePage: true, pageModifier: true, zoomModifier: false) == .page)
    #expect(router.route(phase: .discrete, overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(router.route(phase: .discrete, overActivePage: true, pageModifier: true, zoomModifier: false) == .page)
    #expect(router.locked == nil)
}

@Test func zoomModifierAlwaysCanvas() {
    var router = ScrollRouter()
    _ = router.route(phase: .began, overActivePage: true, pageModifier: true, zoomModifier: false)
    #expect(router.locked == .page)
    #expect(router.route(phase: .changed, overActivePage: true, pageModifier: true, zoomModifier: true) == .canvas)
    #expect(router.locked == .page)
    #expect(router.route(phase: .discrete, overActivePage: true, pageModifier: true, zoomModifier: true) == .canvas)
}
