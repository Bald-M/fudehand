import Testing
@testable import AtlasCore

private let frameA = Rect(x: 0, y: 0, width: 390, height: 888)
private let frameB = Rect(x: 470, y: 0, width: 1440, height: 944)

private func context(selection: Set<String> = [], tool: CanvasTool = .move, spaceHeld: Bool = false,
                     activatable: Set<String> = []) -> InteractionContext {
    InteractionContext(viewport: Viewport(x: 0, y: 0, scale: 0.5),
                       frames: ["a": frameA, "b": frameB],
                       selection: selection, tool: tool, spaceHeld: spaceHeld, activatable: activatable)
}

private func down(_ machine: inout CanvasInteraction, _ x: Double, _ y: Double, hit: HitTarget,
                  button: PointerButton = .primary, modifiers: PointerModifiers = [], clickCount: Int = 1,
                  context: InteractionContext) -> [InteractionEffect] {
    machine.pointerDown(at: Point(x: x, y: y), hit: hit, button: button, modifiers: modifiers,
                        clickCount: clickCount, context: context)
}

private func moveFramesEffects(_ effects: [InteractionEffect]) -> [[String: Point]] {
    effects.compactMap { if case .moveFrames(let p) = $0 { return p } else { return nil } }
}

private func commits(_ effects: [InteractionEffect]) -> [InteractionEffect] {
    effects.filter { if case .commitMove = $0 { return true } else { return false } }
}

private func guides(_ effects: [InteractionEffect]) -> [Guide]? {
    for effect in effects { if case .guides(let g) = effect { return g } }
    return nil
}

@Test func clickingUnselectedFrameSelectsWithoutForwarding() {
    var machine = CanvasInteraction()
    let empty = context()
    #expect(down(&machine, 10, 10, hit: .frameContent("a"), context: empty) == [.select(["a"])])
    #expect(!CanvasInteraction.pageReceivesPointer(hit: .frameContent("a"), button: .primary, context: empty))
    let active = context(selection: ["a"], activatable: ["a"])
    #expect(CanvasInteraction.pageReceivesPointer(hit: .frameContent("a"), button: .primary, context: active))
    #expect(!CanvasInteraction.pageReceivesPointer(hit: .frameContent("a"), button: .middle, context: active))
    #expect(!CanvasInteraction.pageReceivesPointer(hit: .frameHeader("a"), button: .primary, context: active))
    #expect(!CanvasInteraction.pageReceivesPointer(hit: .frameContent("b"), button: .primary, context: active))
    #expect(!CanvasInteraction.pageReceivesPointer(
        hit: .frameContent("a"), button: .primary, context: context(selection: ["a"], tool: .hand, activatable: ["a"])))
    #expect(!CanvasInteraction.pageReceivesPointer(
        hit: .frameContent("a"), button: .primary, context: context(selection: ["a"], spaceHeld: true, activatable: ["a"])))
}

@Test func loadingFrameIsSelectableButNotActive() {
    let loading = context(selection: ["a"])
    #expect(!CanvasInteraction.pageReceivesPointer(hit: .frameContent("a"), button: .primary, context: loading))
}

@Test func smallJitterDoesNotMove() {
    var machine = CanvasInteraction()
    let ctx = context()
    _ = down(&machine, 10, 10, hit: .frameContent("a"), context: ctx)
    let dragged = machine.pointerDragged(to: Point(x: 12, y: 11), modifiers: [], context: ctx)
    #expect(moveFramesEffects(dragged).isEmpty)
    let up = machine.pointerUp(at: Point(x: 12, y: 11), context: ctx)
    #expect(commits(up).isEmpty)
    #expect(machine.isIdle)
}

@Test func dragMovesInWorldUnitsAndCommitsOnce() {
    var machine = CanvasInteraction()
    let ctx = context()
    _ = down(&machine, 10, 10, hit: .frameContent("a"), context: ctx)
    let dragged = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [], context: ctx)
    #expect(moveFramesEffects(dragged) == [["a": Point(x: 200, y: 0)]])
    let up = machine.pointerUp(at: Point(x: 110, y: 10), context: ctx)
    #expect(up.filter { if case .commitMove = $0 { return true } else { return false } }
        == [.commitMove(from: ["a": Point(x: 0, y: 0)], to: ["a": Point(x: 200, y: 0)])])
    #expect(guides(up) == [])
    #expect(machine.isIdle)
}

@Test func dragSnapsAndControlDisablesIt() {
    // Screen dx 38 at scale 0.5 is 76 world units: a.maxX = 466, 4 short of b.minX (470).
    var machine = CanvasInteraction()
    let ctx = context()
    _ = down(&machine, 10, 10, hit: .frameContent("a"), context: ctx)
    let snapped = machine.pointerDragged(to: Point(x: 48, y: 10), modifiers: [], context: ctx)
    #expect(moveFramesEffects(snapped) == [["a": Point(x: 80, y: 0)]])
    #expect(guides(snapped)?.contains(Guide(axis: .vertical, position: 470, start: 0, end: 944)) == true)
    _ = machine.cancel()

    _ = down(&machine, 10, 10, hit: .frameContent("a"), context: ctx)
    let free = machine.pointerDragged(to: Point(x: 48, y: 10), modifiers: [.control], context: ctx)
    #expect(moveFramesEffects(free) == [["a": Point(x: 76, y: 0)]])
    #expect(guides(free) == [])
}

@Test func shiftClickTogglesSelection() {
    var machine = CanvasInteraction()
    let added = down(&machine, 10, 10, hit: .frameContent("a"), modifiers: .shift, context: context(selection: ["b"]))
    #expect(added == [.select(["a", "b"])])
    #expect(machine.isIdle)
    let removed = down(&machine, 10, 10, hit: .frameHeader("a"), modifiers: .shift, context: context(selection: ["a", "b"]))
    #expect(removed == [.select(["b"])])
    #expect(machine.isIdle)
}

@Test func marqueeSelectsIntersectingFrames() {
    var machine = CanvasInteraction()
    let ctx = context()
    #expect(down(&machine, 0, 0, hit: .empty, context: ctx) == [.select([])])
    let dragged = machine.pointerDragged(to: Point(x: 200, y: 100), modifiers: [], context: ctx)
    #expect(dragged == [.marquee(Rect(x: 0, y: 0, width: 200, height: 100)), .select(["a"])])
    #expect(machine.pointerUp(at: Point(x: 200, y: 100), context: ctx) == [.marquee(nil)])
    #expect(machine.isIdle)

    let withB = context(selection: ["b"])
    #expect(down(&machine, 0, 0, hit: .empty, modifiers: .shift, context: withB) == [])
    let extended = machine.pointerDragged(to: Point(x: 200, y: 100), modifiers: .shift, context: withB)
    #expect(extended == [.marquee(Rect(x: 0, y: 0, width: 200, height: 100)), .select(["a", "b"])])
}

@Test func emptyClickClearsSelection() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"])
    #expect(down(&machine, 600, 600, hit: .empty, context: ctx) == [.select([])])
    #expect(machine.pointerUp(at: Point(x: 600, y: 600), context: ctx) == [.marquee(nil)])
}

@Test func multiSelectionMovesTogether() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a", "b"])
    #expect(down(&machine, 10, 10, hit: .frameHeader("a"), context: ctx) == [])
    let dragged = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [.control], context: ctx)
    #expect(moveFramesEffects(dragged) == [["a": Point(x: 200, y: 0), "b": Point(x: 670, y: 0)]])
    let up = machine.pointerUp(at: Point(x: 110, y: 10), context: ctx)
    #expect(commits(up) == [.commitMove(from: ["a": Point(x: 0, y: 0), "b": Point(x: 470, y: 0)],
                                        to: ["a": Point(x: 200, y: 0), "b": Point(x: 670, y: 0)])])
}

@Test func clickInsideMultiSelectionCollapsesOnRelease() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a", "b"])
    #expect(down(&machine, 10, 10, hit: .frameContent("a"), context: ctx) == [])
    #expect(machine.pointerUp(at: Point(x: 10, y: 10), context: ctx) == [.select(["a"])])
    #expect(machine.isIdle)
}

@Test func handToolSpaceAndMiddleButtonPan() {
    let expected: [InteractionEffect] = [.pan(Viewport(x: 30, y: 40, scale: 0.5))]
    let cases: [(PointerButton, InteractionContext)] = [
        (.primary, context(tool: .hand)),
        (.primary, context(spaceHeld: true)),
        (.middle, context()),
    ]
    for (button, ctx) in cases {
        var machine = CanvasInteraction()
        #expect(down(&machine, 0, 0, hit: .frameContent("a"), button: button, context: ctx) == [])
        #expect(machine.pointerDragged(to: Point(x: 30, y: 40), modifiers: [], context: ctx) == expected)
        #expect(machine.pointerUp(at: Point(x: 30, y: 40), context: ctx) == [])
        #expect(machine.isIdle)
    }
}

@Test func doubleClickHeaderFocuses() {
    var machine = CanvasInteraction()
    #expect(down(&machine, 10, 10, hit: .frameHeader("b"), clickCount: 2, context: context()) == [.focus("b")])
    #expect(machine.isIdle)
}

@Test func cancelDuringMoveCommitsOnce() {
    var machine = CanvasInteraction()
    let ctx = context()
    _ = down(&machine, 10, 10, hit: .frameContent("a"), context: ctx)
    _ = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [], context: ctx)
    let cancelled = machine.cancel()
    #expect(commits(cancelled) == [.commitMove(from: ["a": Point(x: 0, y: 0)], to: ["a": Point(x: 200, y: 0)])])
    #expect(machine.cancel() == [])
    #expect(machine.isIdle)
}

@Test func moveEndingAtStartClearsGuidesWithoutCommit() {
    var machine = CanvasInteraction()
    let ctx = context()
    _ = down(&machine, 10, 10, hit: .frameContent("a"), context: ctx)
    _ = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [.control], context: ctx)
    _ = machine.pointerDragged(to: Point(x: 10, y: 10), modifiers: [.control], context: ctx)
    #expect(machine.pointerUp(at: Point(x: 10, y: 10), context: ctx) == [.guides([])])
}

@Test func pointerDownWhileBusyFinishesPreviousGesture() {
    var machine = CanvasInteraction()
    let ctx = context()
    _ = down(&machine, 10, 10, hit: .frameContent("a"), context: ctx)
    _ = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [.control], context: ctx)
    let effects = down(&machine, 600, 600, hit: .empty, context: ctx)
    #expect(effects == [.commitMove(from: ["a": Point(x: 0, y: 0)], to: ["a": Point(x: 200, y: 0)]),
                        .guides([]), .select([])])
}
