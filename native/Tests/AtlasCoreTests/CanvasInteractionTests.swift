import Testing
@testable import AtlasCore

private let rectA = Rect(x: 0, y: 0, width: 390, height: 844)
private let rectB = Rect(x: 470, y: 0, width: 1440, height: 900)

private func context(selection: Set<String> = [], tool: CanvasTool = .move, spaceHeld: Bool = false,
                     movable: Set<String> = ["a", "b"]) -> InteractionContext {
    let rects = ["a": rectA, "b": rectB]
    // Snap targets are the layers other than the one being dragged; the tests always drag a.
    return InteractionContext(viewport: Viewport(x: 0, y: 0, scale: 0.5), rects: rects, marqueeCandidates: ["a", "b"],
                              snapTargets: [rectB], movable: movable, selection: selection, tool: tool, spaceHeld: spaceHeld)
}

private func down(_ machine: inout CanvasInteraction, _ x: Double, _ y: Double, hit: HitTarget,
                  button: PointerButton = .primary, modifiers: PointerModifiers = [], clickCount: Int = 1,
                  context: InteractionContext) -> [InteractionEffect] {
    machine.pointerDown(at: Point(x: x, y: y), hit: hit, button: button, modifiers: modifiers, clickCount: clickCount, context: context)
}

private func moves(_ effects: [InteractionEffect]) -> [[String: Point]] {
    effects.compactMap { if case .moveNodes(let p) = $0 { return p } else { return nil } }
}

private func guides(_ effects: [InteractionEffect]) -> [Guide]? {
    for effect in effects { if case .guides(let g) = effect { return g } }
    return nil
}

@Test func clickingUnselectedNodeSelectsIt() {
    var machine = CanvasInteraction()
    #expect(down(&machine, 10, 10, hit: .node("a"), context: context()) == [.select(["a"])])
    #expect(machine.pointerUp(at: Point(x: 10, y: 10), context: context(selection: ["a"])) == [])
    #expect(down(&machine, 10, 10, hit: .label("b"), context: context()) == [.select(["b"])])
}

@Test func smallJitterDoesNotMove() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"])
    _ = down(&machine, 10, 10, hit: .node("a"), context: ctx)
    #expect(moves(machine.pointerDragged(to: Point(x: 12, y: 11), modifiers: [], context: ctx)).isEmpty)
    #expect(machine.pointerUp(at: Point(x: 12, y: 11), context: ctx) == [])
    #expect(machine.isIdle)
}

@Test func dragMovesInWorldUnitsAsOneGesture() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"])
    _ = down(&machine, 10, 10, hit: .node("a"), context: ctx)
    let first = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [.control], context: ctx)
    #expect(first.first == .beginGesture("Move Layers"))
    #expect(moves(first) == [["a": Point(x: 200, y: 0)]])
    let second = machine.pointerDragged(to: Point(x: 120, y: 10), modifiers: [.control], context: ctx)
    #expect(!second.contains(.beginGesture("Move Layers")))
    #expect(machine.pointerUp(at: Point(x: 120, y: 10), context: ctx) == [.endGesture, .guides([])])
}

@Test func dragSnapsAndControlDisablesIt() {
    // Screen dx 38 at zoom 0.5 is canvas 76: a.maxX = 466, 4 away from b.minX (470).
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"])
    _ = down(&machine, 10, 10, hit: .node("a"), context: ctx)
    let snapped = machine.pointerDragged(to: Point(x: 48, y: 10), modifiers: [], context: ctx)
    #expect(moves(snapped) == [["a": Point(x: 80, y: 0)]])
    #expect(guides(snapped)?.contains(Guide(axis: .vertical, position: 470, start: 0, end: 900)) == true)
    _ = machine.cancel()
    _ = down(&machine, 10, 10, hit: .node("a"), context: ctx)
    let free = machine.pointerDragged(to: Point(x: 48, y: 10), modifiers: [.control], context: ctx)
    #expect(moves(free) == [["a": Point(x: 76, y: 0)]])
}

@Test func immovableNodeDoesNotMove() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"], movable: ["b"])
    _ = down(&machine, 10, 10, hit: .node("a"), context: ctx)
    #expect(machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [], context: ctx) == [])
    #expect(machine.pointerDragged(to: Point(x: 150, y: 10), modifiers: [], context: ctx) == [])
    #expect(machine.pointerUp(at: Point(x: 150, y: 10), context: ctx) == [])
}

@Test func shiftClickTogglesSelection() {
    var machine = CanvasInteraction()
    #expect(down(&machine, 10, 10, hit: .node("a"), modifiers: .shift, context: context(selection: ["b"])) == [.select(["a", "b"])])
    #expect(down(&machine, 10, 10, hit: .node("a"), modifiers: .shift, context: context(selection: ["a", "b"])) == [.select(["b"])])
    #expect(machine.isIdle)
}

@Test func marqueeSelectsIntersectingCandidates() {
    var machine = CanvasInteraction()
    let ctx = context()
    #expect(down(&machine, 0, 0, hit: .empty, context: ctx) == [.select([])])
    #expect(machine.pointerDragged(to: Point(x: 200, y: 100), modifiers: [], context: ctx)
            == [.marquee(Rect(x: 0, y: 0, width: 200, height: 100)), .select(["a"])])
    #expect(machine.pointerUp(at: Point(x: 200, y: 100), context: ctx) == [.marquee(nil)])
    let withB = context(selection: ["b"])
    #expect(down(&machine, 0, 0, hit: .empty, modifiers: .shift, context: withB) == [])
    #expect(machine.pointerDragged(to: Point(x: 200, y: 100), modifiers: .shift, context: withB)
            == [.marquee(Rect(x: 0, y: 0, width: 200, height: 100)), .select(["a", "b"])])
}

@Test func multiSelectionMovesTogetherAndCollapsesOnClick() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a", "b"])
    #expect(down(&machine, 10, 10, hit: .node("a"), context: ctx) == [])
    let dragged = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [.control], context: ctx)
    #expect(moves(dragged) == [["a": Point(x: 200, y: 0), "b": Point(x: 670, y: 0)]])
    _ = machine.pointerUp(at: Point(x: 110, y: 10), context: ctx)
    #expect(down(&machine, 10, 10, hit: .node("a"), context: ctx) == [])
    #expect(machine.pointerUp(at: Point(x: 10, y: 10), context: ctx) == [.select(["a"])])
}

@Test func handToolSpaceAndMiddleButtonPan() {
    let expected: [InteractionEffect] = [.pan(Viewport(x: 30, y: 40, scale: 0.5))]
    for (button, ctx) in [(PointerButton.primary, context(tool: .hand)), (.primary, context(spaceHeld: true)),
                          (.middle, context()), (.primary, context(tool: .rectangle, spaceHeld: true))] {
        var machine = CanvasInteraction()
        #expect(down(&machine, 0, 0, hit: .node("a"), button: button, context: ctx) == [])
        #expect(machine.pointerDragged(to: Point(x: 30, y: 40), modifiers: [], context: ctx) == expected)
        #expect(machine.pointerUp(at: Point(x: 30, y: 40), context: ctx) == [])
    }
}

@Test func doubleClicks() {
    var machine = CanvasInteraction()
    #expect(down(&machine, 10, 10, hit: .label("b"), clickCount: 2, context: context()) == [.focus("b")])
    #expect(down(&machine, 10, 20, hit: .node("a"), clickCount: 2, context: context(selection: ["a"])) == [.enter("a", Point(x: 20, y: 40))])
    // When double-clicking an unselected layer, the first click already selects it and the second is handled as an ordinary press.
    #expect(down(&machine, 10, 20, hit: .node("a"), clickCount: 2, context: context(selection: ["b"])) == [.select(["a"])])
}

@Test func handleDragResizes() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"])
    #expect(down(&machine, 0, 0, hit: .handle("a", .bottomRight), context: ctx) == [])
    #expect(machine.pointerDragged(to: Point(x: 10, y: 20), modifiers: [], context: ctx)
            == [.beginGesture("Resize"), .resize("a", Rect(x: 0, y: 0, width: 410, height: 884))])
    #expect(machine.pointerDragged(to: Point(x: -5, y: 0), modifiers: [], context: ctx) == [.resize("a", Rect(x: 0, y: 0, width: 380, height: 844))])
    #expect(machine.pointerUp(at: Point(x: -5, y: 0), context: ctx) == [.endGesture])
    // Clicking a handle without dragging produces no edit.
    _ = down(&machine, 0, 0, hit: .handle("a", .left), context: ctx)
    #expect(machine.pointerUp(at: Point(x: 0, y: 0), context: ctx) == [])
}

@Test func resizeClampsAndMovesOppositeEdges() {
    let rect = Rect(x: 10, y: 10, width: 100, height: 50)
    #expect(CanvasInteraction.resized(rect, handle: .topLeft, by: Point(x: 20, y: 10)) == Rect(x: 30, y: 20, width: 80, height: 40))
    #expect(CanvasInteraction.resized(rect, handle: .left, by: Point(x: 500, y: 0)) == Rect(x: 109, y: 10, width: 1, height: 50))
    #expect(CanvasInteraction.resized(rect, handle: .top, by: Point(x: 50, y: 0)) == rect)
}

@Test func creationToolDragsOrClicksDefaultSize() {
    var machine = CanvasInteraction()
    let ctx = context(tool: .rectangle)
    #expect(down(&machine, 100, 100, hit: .node("a"), context: ctx) == [])
    #expect(machine.pointerDragged(to: Point(x: 50, y: 160), modifiers: [], context: ctx) == [.marquee(Rect(x: 50, y: 100, width: 50, height: 60))])
    #expect(machine.pointerUp(at: Point(x: 50, y: 160), context: ctx) == [.marquee(nil), .create(.rectangle, Rect(x: 100, y: 200, width: 100, height: 120))])
    _ = down(&machine, 10, 10, hit: .empty, context: context(tool: .text))
    #expect(machine.pointerUp(at: Point(x: 11, y: 10), context: context(tool: .text)) == [.marquee(nil), .create(.text, Rect(x: 20, y: 20, width: 100, height: 100))])
}

@Test func cancelEndsGestureOnce() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"])
    _ = down(&machine, 10, 10, hit: .node("a"), context: ctx)
    _ = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [], context: ctx)
    #expect(machine.cancel() == [.endGesture, .guides([])])
    #expect(machine.cancel() == [])
    #expect(machine.isIdle)
}

@Test func pointerDownWhileBusyFinishesPreviousGesture() {
    var machine = CanvasInteraction()
    let ctx = context(selection: ["a"])
    _ = down(&machine, 10, 10, hit: .node("a"), context: ctx)
    _ = machine.pointerDragged(to: Point(x: 110, y: 10), modifiers: [.control], context: ctx)
    #expect(down(&machine, 600, 600, hit: .empty, context: ctx) == [.endGesture, .guides([]), .select([])])
}
