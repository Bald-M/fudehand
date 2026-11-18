import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Forwards to the real store while recording the stable viewport the canvas reports.
@MainActor
final class RecordingHost: CanvasHost {
    let store: FudehandStore
    var settled: [Viewport] = []
    init(_ store: FudehandStore) { self.store = store }
    func canvasSelect(_ ids: Set<String>) { store.canvasSelect(ids) }
    func canvasBeginGesture(_ name: String) { store.canvasBeginGesture(name) }
    func canvasMove(_ origins: [String: Point]) { store.canvasMove(origins) }
    func canvasResize(_ id: String, to rect: Rect) { store.canvasResize(id, to: rect) }
    func canvasEndGesture() { store.canvasEndGesture() }
    func canvasCreate(_ type: NodeType, in rect: Rect, clicked: Bool) { store.canvasCreate(type, in: rect, clicked: clicked) }
    func canvasNudge(_ ids: Set<String>, by delta: Point) { store.canvasNudge(ids, by: delta) }
    func canvasDelete(_ ids: Set<String>) { store.canvasDelete(ids) }
    func canvasToolChanged(_ tool: CanvasTool) { store.canvasToolChanged(tool) }
    func canvasCommand(_ command: CanvasCommand) { store.canvasCommand(command) }
    func canvasFocus(_ id: String) { store.canvasFocus(id) }
    func canvasViewportSettled(_ viewport: Viewport) { settled.append(viewport); store.canvasViewportSettled(viewport) }
    func canvasSizeChanged(_ size: CGSize) { store.canvasSizeChanged(size) }
    func canvasHover(_ id: String?) { store.canvasHover(id) }
}

/// Top-level frame a (0,0 400×300, containing card 20,20 100×50) and rectangle b (600,0 300×300); viewport (0, 100) at 100%, with the frame's name label visible on screen.
@MainActor
final class CanvasHarness {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: FudehandCanvasView
    let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!)
    let host: RecordingHost
    private var token = 1

    nonisolated static func document() -> DesignDocument {
        var frame = DesignNode(id: "a", type: .frame, name: "Home", width: 400, height: 300)
        frame.fill = .white
        var card = DesignNode(id: "card", type: .rectangle, x: 20, y: 20, width: 100, height: 50)
        card.fill = .black
        frame.children = [card]
        return DesignDocument(nodes: [frame, DesignNode(id: "b", type: .rectangle, x: 600, y: 0, width: 300, height: 300)])
    }

    init(document: DesignDocument = CanvasHarness.document()) {
        canvas = FudehandCanvasView(frame: window.contentLayoutRect)
        host = RecordingHost(store)
        window.contentView = canvas
        canvas.host = host
        store.attach(canvas)
        store.replace(document, url: nil)
        request(Viewport(x: 0, y: 100, scale: 1))
        canvas.layoutSubtreeIfNeeded()
    }

    func request(_ viewport: Viewport, animated: Bool = false) {
        token += 1
        canvas.update(viewportRequest: ViewportRequest(viewport: viewport, animated: animated, token: token), tool: store.tool)
    }

    func setTool(_ tool: CanvasTool) {
        store.tool = tool
        canvas.update(viewportRequest: ViewportRequest(viewport: Viewport(), animated: false, token: token), tool: tool)
    }

    /// `point` is in canvas (flipped, screen-space) coordinates.
    func send(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        let event = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags,
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: clicks, pressure: 1)!
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        case .mouseMoved: canvas.mouseMoved(with: event)
        default: Issue.record("Unhandled event type \(type)")
        }
    }

    func click(_ point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        send(.leftMouseDown, at: point, flags: flags, clicks: clicks)
        send(.leftMouseUp, at: point, flags: flags, clicks: clicks)
    }

    func drag(from start: NSPoint, to end: NSPoint, flags: NSEvent.ModifierFlags = [], release: Bool = true) {
        send(.leftMouseDown, at: start, flags: flags)
        send(.leftMouseDragged, at: NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), flags: flags)
        send(.leftMouseDragged, at: end, flags: flags)
        if release { send(.leftMouseUp, at: end, flags: flags) }
    }

    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], chars: String = "") throws {
        window.makeFirstResponder(canvas)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        canvas.keyDown(with: event)
    }

    func node(_ id: String) -> DesignNode? { store.editor.document.node(id) }
    func dispose() { canvas.dispose() }
}

@Test @MainActor func clickSelectsChildOfFrameFrameBackgroundOrNothing() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.click(NSPoint(x: 50, y: 140))
    #expect(h.store.selection == ["card"])
    h.click(NSPoint(x: 300, y: 300))
    #expect(h.store.selection == ["a"])
    h.click(NSPoint(x: 500, y: 600))
    #expect(h.store.selection.isEmpty)
    h.click(NSPoint(x: 50, y: 140), flags: .command)
    #expect(h.store.selection == ["card"])
}

@Test @MainActor func frameLabelSelectsAndDoubleClickFocuses() {
    let h = CanvasHarness()
    defer { h.dispose() }
    #expect(h.canvas.hitTarget(at: NSPoint(x: 5, y: 88)) == .label("a"))
    h.click(NSPoint(x: 5, y: 88))
    #expect(h.store.selection == ["a"])
    #expect(h.canvas.overlay.labelTexts == ["a": "Home"])
}

@Test @MainActor func dragMovesAsOneUndoStep() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.drag(from: NSPoint(x: 700, y: 200), to: NSPoint(x: 750, y: 230), flags: .control)
    #expect(h.node("b")?.frame == Rect(x: 650, y: 30, width: 300, height: 300))
    #expect(h.store.editor.undoName == "Move Layers")
    h.store.undo()
    #expect(h.node("b")?.x == 600)
    #expect(!h.store.canUndo)
}

@Test @MainActor func childOfAutoLayoutFrameDoesNotMoveByDrag() throws {
    var document = CanvasHarness.document()
    try document.update("a") { $0.layout = AutoLayout(direction: .vertical, padding: EdgeInsets(top: 20, left: 20)) }
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    h.drag(from: NSPoint(x: 50, y: 140), to: NSPoint(x: 150, y: 240))
    #expect(h.store.selection == ["card"])
    #expect(h.node("card").map { Point(x: $0.x, y: $0.y) } == Point(x: 20, y: 20))
    #expect(!h.store.canUndo)
}

@Test @MainActor func handleResizesSelection() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.click(NSPoint(x: 700, y: 200))
    #expect(h.canvas.hitTarget(at: NSPoint(x: 900, y: 400)) == .handle("b", .bottomRight))
    h.drag(from: NSPoint(x: 900, y: 400), to: NSPoint(x: 950, y: 420))
    #expect(h.node("b")?.frame == Rect(x: 600, y: 0, width: 350, height: 320))
    h.store.undo()
    #expect(h.node("b")?.width == 300)
}

@Test @MainActor func marqueeSelectsTopLevelLayers() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.drag(from: NSPoint(x: 550, y: 650), to: NSPoint(x: 650, y: 380))
    #expect(h.store.selection == ["b"])
}

@Test @MainActor func creationToolDrawsInsideFrameAndReturnsToMove() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.setTool(.rectangle)
    h.drag(from: NSPoint(x: 200, y: 300), to: NSPoint(x: 260, y: 340))
    let id = try #require(h.store.selection.first)
    #expect(h.store.editor.document.parentID(of: id) == .some("a"))
    #expect(h.node(id)?.frame == Rect(x: 200, y: 200, width: 60, height: 40))
    #expect(h.store.tool == .move)
    h.setTool(.text)
    h.click(NSPoint(x: 700, y: 600))
    let text = try #require(h.store.selection.first.flatMap(h.node))
    #expect(text.type == .text && text.text?.content == "Text" && text.width > 0)
    #expect(h.store.editor.document.parentID(of: text.id) == .some(nil))
}

@Test @MainActor func textDraggedToTheDefaultSizeKeepsItsDraggedWidth() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.setTool(.text)
    h.drag(from: NSPoint(x: 700, y: 500), to: NSPoint(x: 800, y: 600))
    let text = try #require(h.store.selection.first.flatMap(h.node))
    #expect(text.text?.autoResize == .height && text.width == 100)
}

@Test @MainActor func keyboardNudgesDeletesAndNavigatesLevels() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.click(NSPoint(x: 700, y: 200))
    try h.key(124)
    #expect(h.node("b")?.x == 601)
    try h.key(125, .shift)
    #expect(h.node("b")?.y == 10)
    h.click(NSPoint(x: 50, y: 140))
    try h.key(53)
    #expect(h.store.selection == ["a"])
    try h.key(36)
    #expect(h.store.selection == ["card"])
    try h.key(53)
    try h.key(53)
    #expect(h.store.selection.isEmpty)
    try h.key(0, .command, chars: "a")
    #expect(h.store.selection == ["a", "b"])
    h.click(NSPoint(x: 700, y: 200))
    try h.key(51)
    #expect(h.node("b") == nil && h.store.selection.isEmpty)
    try h.key(15, chars: "r")
    #expect(h.store.tool == .rectangle)
}

@Test @MainActor func focusLossDuringDragKeepsTheMoveAsOneStep() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.drag(from: NSPoint(x: 700, y: 200), to: NSPoint(x: 800, y: 200), flags: .control, release: false)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: h.window)
    #expect(h.node("b")?.x == 700)
    h.store.undo()
    #expect(h.node("b")?.x == 600)
}

@Test @MainActor func canvasKeysOnlyApplyWhenTheCanvasIsFirstResponder() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    final class Acceptor: NSView { override var acceptsFirstResponder: Bool { true } }
    let inner = Acceptor()
    h.canvas.addSubview(inner)
    #expect(h.window.makeFirstResponder(inner))
    let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
                                              context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    h.canvas.keyDown(with: space)
    #expect(!h.canvas.spaceHeld)
    #expect(h.window.makeFirstResponder(h.canvas))
    h.canvas.keyDown(with: space)
    #expect(h.canvas.spaceHeld)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: h.window)
    #expect(!h.canvas.spaceHeld)
}

@Test @MainActor func nestedLayerMovesAndResizesInCanvasCoordinates() {
    var document = CanvasHarness.document()
    document.nodes[0].x = 40
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    // card sits at canvas (60,20), screen (60,120).
    h.drag(from: NSPoint(x: 100, y: 140), to: NSPoint(x: 130, y: 150), flags: .control)
    #expect(h.store.selection == ["card"])
    #expect(h.node("card")?.frame == Rect(x: 50, y: 30, width: 100, height: 50))
    #expect(h.node("a")?.x == 40)
    #expect(h.canvas.hitTarget(at: NSPoint(x: 190, y: 180)) == .handle("card", .bottomRight))
    h.drag(from: NSPoint(x: 190, y: 180), to: NSPoint(x: 200, y: 200))
    #expect(h.node("card")?.frame == Rect(x: 50, y: 30, width: 110, height: 70))
    h.store.undo()
    h.store.undo()
    #expect(h.node("card")?.frame == Rect(x: 20, y: 20, width: 100, height: 50))
}

@Test @MainActor func selectionAndHandlesFollowUndoneLayers() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.setTool(.rectangle)
    h.drag(from: NSPoint(x: 500, y: 500), to: NSPoint(x: 560, y: 540))
    #expect(h.store.selection.count == 1 && h.canvas.handleTarget != nil)
    h.store.undo()
    #expect(h.store.selection.isEmpty && h.canvas.selection.isEmpty && h.canvas.handleTarget == nil)
    #expect(h.canvas.overlay.selectionBounds.isNull)
}

// MARK: Viewport

@Test func frameIntervalLogCountsHitchesOncePerSecond() {
    var log = FrameIntervalLog()
    #expect(log.record(10.0) == nil)
    #expect(log.record(10.016) == nil)
    #expect(log.record(10.066) == nil)
    #expect(log.record(10.086) == nil)
    #expect(log.record(11.0) == "[frame] hitches=2 frames=4")
    #expect(log.record(11.016) == nil)
    #expect(log.record(12.0) == "[frame] hitches=1 frames=2")
}

@Test @MainActor func pointerDownCommitsPendingZoom() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.request(Viewport(x: 0, y: 0, scale: 1))
    let before = h.canvas.worldBounds
    h.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    #expect(h.canvas.worldBounds == before)
    #expect(h.host.settled.isEmpty)
    h.send(.leftMouseDown, at: NSPoint(x: 990, y: 690))
    #expect(h.canvas.worldBounds == NSRect(x: 0, y: 0, width: before.width / 2, height: before.height / 2))
    #expect(h.host.settled == [Viewport(x: 0, y: 0, scale: 2)])
    #expect(h.canvas.renderer.contentsScale == 2 * (h.window.backingScaleFactor))
}

@Test func rasterZoomRoundsUpToPowersOfTwo() {
    #expect(FudehandCanvasView.rasterZoom(0.05) == 0.25)
    #expect(FudehandCanvasView.rasterZoom(0.3) == 0.5)
    #expect(FudehandCanvasView.rasterZoom(0.5) == 0.5)
    #expect(FudehandCanvasView.rasterZoom(0.9) == 1)
    #expect(FudehandCanvasView.rasterZoom(1) == 1)
    #expect(FudehandCanvasView.rasterZoom(1.2) == 2)
    #expect(FudehandCanvasView.rasterZoom(4) == 4)
}

@Test @MainActor func pendingZoomHitTestUsesLiveViewport() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.request(Viewport(x: 0, y: 0, scale: 1))
    h.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    // Frame a is magnified to 0–800 on screen; rectangle b starts at screen 1200.
    #expect(h.canvas.hitTarget(at: NSPoint(x: 700, y: 300)) == .node("a"))
    #expect(h.canvas.hitTarget(at: NSPoint(x: 900, y: 300)) == .empty)
}

@Test @MainActor func animatedRequestSettlesAtTarget() {
    let h = CanvasHarness()
    defer { h.dispose() }
    let target = Viewport(x: -200, y: -100, scale: 0.5)
    h.request(target, animated: true)
    h.canvas.advanceAnimation(to: 0.5)
    #expect(h.host.settled.isEmpty)
    h.canvas.advanceAnimation(to: 1)
    #expect(h.host.settled == [target])
    #expect(h.canvas.worldBounds == NSRect(x: 400, y: 200, width: 2000, height: 1400))
}

@Test @MainActor func pinchWithoutAnEndSettlesAfterIdle() async throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.request(Viewport(x: 0, y: 0, scale: 1))
    h.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    try await Task.sleep(for: .milliseconds(250))
    #expect(h.host.settled == [Viewport(x: 0, y: 0, scale: 2)])
    #expect(!h.canvas.isZoomPending)
}

@Test @MainActor func gridHidesWhenDense() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.request(Viewport(x: 0, y: 0, scale: 0.2))
    #expect(h.canvas.gridLayer.isHidden)
    h.request(Viewport(x: 0, y: 0, scale: 1))
    #expect(!h.canvas.gridLayer.isHidden)
}

@Test @MainActor func hoveringALayerRowOutlinesTheLayerOnTheCanvas() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.store.setHover("card")
    #expect(h.canvas.hover == "card" && h.store.hover.id == "card")
    h.store.setHover(nil)
    #expect(h.canvas.hover == nil && h.store.hover.id == nil)
}

@Test @MainActor func hoveringALayerOnTheCanvasHighlightsItsLayerRow() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.send(.mouseMoved, at: NSPoint(x: 50, y: 140))
    #expect(h.store.hover.id == "card")
    h.send(.mouseMoved, at: NSPoint(x: 500, y: 600))
    #expect(h.store.hover.id == nil)
}

@Test @MainActor func deletingTheHoveredLayerClearsTheHover() {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.store.setHover("b")
    h.store.canvasDelete(["b"])
    #expect(h.canvas.hover == nil && h.store.hover.id == nil)
}

/// The bottom toolbar offers every canvas tool once, labelled with the key the canvas switches to it on.
@Test @MainActor func canvasToolbarListsEveryToolWithItsShortcutKey() {
    #expect(CanvasToolbar.tools.map(\.0) == CanvasTool.allCases)
    for (tool, _, key, _) in CanvasToolbar.tools {
        #expect(FudehandCanvasView.toolKeys[key.lowercased()] == tool)
    }
}

/// The workspace tells the canvas where the bottom toolbar floats: centered, 16pt above the canvas's bottom edge.
@Test @MainActor func workspaceReportsTheBottomToolbarFrameToTheCanvas() throws {
    let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = NSHostingView(rootView: WorkspaceView(store: store))
    window.layoutIfNeeded()
    func find(_ view: NSView) -> FudehandCanvasView? { view as? FudehandCanvasView ?? view.subviews.lazy.compactMap(find).first }
    let root = try #require(window.contentView)
    let canvas = try #require(find(root))
    defer { canvas.dispose() }
    // The frame arrives on the SwiftUI update after layout.
    for _ in 0..<20 where canvas.floatingFrame.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let frame = canvas.floatingFrame
    #expect(frame.width > 200 && frame.height > 30)
    #expect(abs(frame.midX - canvas.bounds.midX) <= 1)
    #expect(abs(frame.maxY - (canvas.bounds.maxY - 16)) <= 1)
}

/// SwiftUI passes the pointer events the toolbar does not handle to the canvas underneath; the canvas drops them.
@Test @MainActor func canvasIgnoresPointerInputOverTheFloatingToolbar() throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.canvas.floatingFrame = CGRect(x: 360, y: 620, width: 280, height: 44)
    h.click(NSPoint(x: 50, y: 140))
    #expect(h.store.selection == ["card"])
    h.click(NSPoint(x: 380, y: 640))
    #expect(h.store.selection == ["card"])
    h.setTool(.rectangle)
    h.drag(from: NSPoint(x: 380, y: 640), to: NSPoint(x: 600, y: 400))
    #expect(h.store.editor.document.nodes.count == 2)
    #expect(h.store.tool == .rectangle)
    h.setTool(.hand)
    h.drag(from: NSPoint(x: 380, y: 640), to: NSPoint(x: 600, y: 400))
    #expect(h.canvas.liveViewport == Viewport(x: 0, y: 100, scale: 1))

    // A windowless scroll event carries its location in screen coordinates; the harness window sits at the screen origin.
    func scroll(at point: NSPoint) throws {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -40, wheel2: 0, wheel3: 0))
        let target = h.canvas.convert(point, to: nil)
        cg.location = CGPoint(x: target.x, y: CGDisplayBounds(CGMainDisplayID()).height - target.y)
        let event = try #require(NSEvent(cgEvent: cg))
        h.canvas.scrollWheel(with: event)
    }
    try scroll(at: NSPoint(x: 380, y: 640))
    #expect(h.canvas.liveViewport == Viewport(x: 0, y: 100, scale: 1))
    try scroll(at: NSPoint(x: 380, y: 300))
    #expect(h.canvas.liveViewport != Viewport(x: 0, y: 100, scale: 1))
}
