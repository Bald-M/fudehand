import AppKit
import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

/// A window holding a canvas with frames "a" (0,0 400×300) and "b" (600,0 300×300) at 100% zoom.
@MainActor
private final class CanvasHarness {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled],
                          backing: .buffered, defer: true)
    let canvas: AtlasCanvasView
    var selections: [Set<String>] = []
    var moves: [[String: Point]] = []

    init() {
        canvas = AtlasCanvasView(frame: window.contentLayoutRect)
        window.contentView = canvas
        canvas.onSelectionChange = { [unowned self] in selections.append($0) }
        canvas.onFramesMoved = { [unowned self] in moves.append($0) }
        load(Self.project(id: "first"))
    }

    static func project(id: String) -> Project {
        let preview = Preview(cwd: "examples/demo", command: ["pnpm", "dev"], port: 4401, baseUrl: "http://127.0.0.1:4401/")
        let frames = [
            Frame(id: "a", title: "首页", platform: "web", path: "/", width: 400, height: 300, x: 0, y: 0),
            Frame(id: "b", title: "手机", platform: "mobile", path: "/m", width: 300, height: 300, x: 600, y: 0),
        ]
        return Project(id: id, title: "作品 \(id)", subtitle: "", description: "", author: "", sourceUrl: nil,
                       framework: "HTML", tags: [], enabled: true, layoutVersion: 1, preview: preview, frames: frames)
    }

    func load(_ project: Project) {
        canvas.update(project: project, positions: [:], positionsToken: 1,
                      viewportRequest: ViewportRequest(viewport: Viewport(x: 0, y: 0, scale: 1), animated: false, token: 1),
                      tool: .move, reloadToken: 0)
        canvas.layoutSubtreeIfNeeded()
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
        default: Issue.record("未处理的事件类型 \(type)")
        }
    }

    func drag(from start: NSPoint, to end: NSPoint, release: Bool = true) {
        send(.leftMouseDown, at: start)
        send(.leftMouseDragged, at: NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        send(.leftMouseDragged, at: end)
        if release { send(.leftMouseUp, at: end) }
    }

    func dispose() { canvas.dispose() }
}

@Test @MainActor func clickSelectsAndReportsSelection() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    let content = NSPoint(x: 100, y: 150)
    harness.send(.leftMouseDown, at: content)
    harness.send(.leftMouseUp, at: content)
    #expect(harness.selections.last == ["a"])
    #expect(harness.canvas.hitTarget(at: content) == .frameContent("a"))
    #expect(harness.canvas.hitTarget(at: NSPoint(x: 100, y: 20)) == .frameHeader("a"))
    #expect(harness.canvas.hitTarget(at: NSPoint(x: 500, y: 150)) == .empty)
    // The page has not finished loading, so a second click still goes to the canvas.
    let canvas = harness.canvas
    #expect(canvas.hitTest(canvas.convert(content, to: canvas.superview)) === canvas)
}

@Test @MainActor func dragCommitsAndUndoRestores() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    harness.drag(from: NSPoint(x: 100, y: 150), to: NSPoint(x: 200, y: 150))
    #expect(harness.moves == [["a": Point(x: 100, y: 0)]])
    let undoManager = try #require(harness.window.undoManager)
    #expect(undoManager.undoActionName == "移动画框")
    undoManager.undo()
    #expect(harness.moves.last == ["a": Point(x: 0, y: 0)])
    undoManager.redo()
    #expect(harness.moves.last == ["a": Point(x: 100, y: 0)])
    #expect(harness.moves.count == 3)
}

@Test @MainActor func focusLossCommitsMove() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    harness.drag(from: NSPoint(x: 100, y: 150), to: NSPoint(x: 200, y: 150), release: false)
    #expect(harness.moves.isEmpty)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: harness.window)
    harness.send(.leftMouseUp, at: NSPoint(x: 200, y: 150))
    #expect(harness.moves == [["a": Point(x: 100, y: 0)]])
}

@Test @MainActor func switchingProjectClearsUndo() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    harness.drag(from: NSPoint(x: 100, y: 150), to: NSPoint(x: 200, y: 150))
    let undoManager = try #require(harness.window.undoManager)
    #expect(undoManager.canUndo)
    // The undo manager closes the event's undo group when the run loop turns, as after a real mouse-up.
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    harness.load(CanvasHarness.project(id: "second"))
    #expect(!undoManager.canUndo)
}

@Test @MainActor func marqueeOnEmptyCanvasSelectsIntersectingFrames() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    harness.drag(from: NSPoint(x: 20, y: 600), to: NSPoint(x: 700, y: 300))
    #expect(harness.selections.last == ["a", "b"])
    harness.send(.leftMouseDown, at: NSPoint(x: 500, y: 600))
    harness.send(.leftMouseUp, at: NSPoint(x: 500, y: 600))
    #expect(harness.selections.last == [])
}

@Test @MainActor func shiftClickTogglesFrameInSelection() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    harness.send(.leftMouseDown, at: NSPoint(x: 100, y: 150))
    harness.send(.leftMouseUp, at: NSPoint(x: 100, y: 150))
    harness.send(.leftMouseDown, at: NSPoint(x: 700, y: 20), flags: .shift)
    harness.send(.leftMouseUp, at: NSPoint(x: 700, y: 20), flags: .shift)
    #expect(harness.selections.last == ["a", "b"])
}

@Test @MainActor func arrowNudgeMovesTheSelectionOutline() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    harness.send(.leftMouseDown, at: NSPoint(x: 100, y: 150))
    harness.send(.leftMouseUp, at: NSPoint(x: 100, y: 150))
    let before = harness.canvas.overlay.selectionBounds
    #expect(!before.isNull)
    #expect(harness.window.firstResponder === harness.canvas)
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: harness.window.windowNumber, context: nil, characters: "",
                                              charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    harness.canvas.keyDown(with: right)
    #expect(harness.moves.last == ["a": Point(x: 10, y: 0)])
    #expect(harness.canvas.overlay.selectionBounds.minX == before.minX + 10)
}

@Test @MainActor func disposingClearsUndo() throws {
    let harness = CanvasHarness()
    harness.drag(from: NSPoint(x: 100, y: 150), to: NSPoint(x: 200, y: 150))
    let undoManager = try #require(harness.window.undoManager)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    #expect(undoManager.canUndo)
    harness.dispose()
    #expect(!undoManager.canUndo)
}

/// Selects "a" and marks its page loaded so it becomes the active frame.
@MainActor private func activateA(_ harness: CanvasHarness) throws -> PreviewFrameView {
    harness.send(.leftMouseDown, at: NSPoint(x: 100, y: 150))
    harness.send(.leftMouseUp, at: NSPoint(x: 100, y: 150))
    let frame = try #require(harness.canvas.frames["a"])
    frame.isReady = true
    return frame
}

@Test @MainActor func activePageRoutingHonorsShiftAndButtonNumber() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    let frame = try activateA(harness)
    let canvas = harness.canvas
    let point = canvas.convert(NSPoint(x: 100, y: 150), to: canvas.superview)
    func click(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags, timestamp: 0,
                           windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func other(_ button: UInt32) throws -> NSEvent {
        let mouseButton = try #require(CGMouseButton(rawValue: button))
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                      mouseButton: mouseButton))
        return try #require(NSEvent(cgEvent: cg))
    }
    func goesToPage(_ event: NSEvent) -> Bool {
        guard let view = canvas.hitTest(point, event: event) else { return false }
        return view !== canvas && view.isDescendant(of: frame)
    }
    #expect(goesToPage(click([])))
    #expect(canvas.hitTest(point, event: click(.shift)) === canvas)
    #expect(canvas.hitTest(point, event: try other(2)) === canvas)
    #expect(goesToPage(try other(3)))
}

@Test @MainActor func pageThatStopsBeingReadyReturnsFocusToCanvas() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    let frame = try activateA(harness)
    // Stands in for the frame's WKWebView holding focus.
    final class Acceptor: NSView { override var acceptsFirstResponder: Bool { true } }
    let inner = Acceptor()
    frame.addSubview(inner)
    #expect(harness.window.makeFirstResponder(inner))
    frame.isReady = false
    #expect(harness.window.firstResponder === harness.canvas)
}

@MainActor private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], chars: String = "", window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: chars,
                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
}

@MainActor private func select(_ harness: CanvasHarness, at point: NSPoint = NSPoint(x: 100, y: 150)) {
    harness.send(.leftMouseDown, at: point)
    harness.send(.leftMouseUp, at: point)
}

@Test @MainActor func arrowKeysNudgeSelectionAndUndoAsOneStep() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    select(harness)
    let undoManager = try #require(harness.window.undoManager)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    harness.canvas.keyDown(with: try key(124, window: harness.window))
    #expect(harness.moves.last == ["a": Point(x: 10, y: 0)])
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    harness.canvas.keyDown(with: try key(124, .shift, window: harness.window))
    #expect(harness.moves.last == ["a": Point(x: 110, y: 0)])
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    undoManager.undo()
    #expect(harness.moves.last == ["a": Point(x: 10, y: 0)])
    #expect(undoManager.canUndo)
}

@Test @MainActor func shiftDigitsIssueCommands() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var commands: [CanvasCommand] = []
    harness.canvas.onCommand = { commands.append($0) }
    select(harness, at: NSPoint(x: 500, y: 600))
    for code: UInt16 in [18, 19, 29] { harness.canvas.keyDown(with: try key(code, .shift, window: harness.window)) }
    harness.canvas.keyDown(with: try key(18, [.shift, .command], window: harness.window))
    harness.canvas.keyDown(with: try key(18, window: harness.window))
    #expect(commands == [.fitAll, .zoomToSelection, .actualSize])
}

@Test @MainActor func toolKeysReportToolChange() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var tools: [CanvasTool] = []
    harness.canvas.onToolChange = { tools.append($0) }
    select(harness, at: NSPoint(x: 500, y: 600))
    // Key codes are deliberately those of other letters: the character decides, not the QWERTY position.
    harness.canvas.keyDown(with: try key(0, chars: "h", window: harness.window))
    harness.canvas.keyDown(with: try key(0, chars: "V", window: harness.window))
    harness.canvas.keyDown(with: try key(9, chars: "x", window: harness.window))
    harness.canvas.keyDown(with: try key(4, .command, chars: "h", window: harness.window))
    #expect(tools == [.hand, .move])
}

@Test @MainActor func escapeClearsSelectionAndSelectAllSelectsEveryFrame() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    select(harness)
    harness.canvas.keyDown(with: try key(53, window: harness.window))
    #expect(harness.selections.last == [])
    harness.canvas.keyDown(with: try key(0, .command, window: harness.window))
    #expect(harness.selections.last == ["a", "b"])
}

@Test @MainActor func returnFocusesOnlyAReadySingleSelection() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    select(harness)
    let frame = try #require(harness.canvas.frames["a"])
    harness.canvas.keyDown(with: try key(36, window: harness.window))
    #expect(harness.window.firstResponder === harness.canvas)
    frame.isReady = true
    harness.canvas.keyDown(with: try key(36, window: harness.window))
    #expect(harness.window.firstResponder === frame.pageView)
}

@Test func scrollPhaseMapping() {
    typealias Canvas = AtlasCanvasView
    #expect(Canvas.scrollPhase([], momentum: []) == .discrete)
    #expect(Canvas.scrollPhase(.mayBegin, momentum: []) == .began)
    #expect(Canvas.scrollPhase(.began, momentum: []) == .began)
    #expect(Canvas.scrollPhase(.changed, momentum: []) == .changed)
    #expect(Canvas.scrollPhase(.ended, momentum: []) == .ended)
    #expect(Canvas.scrollPhase(.cancelled, momentum: []) == .ended)
    #expect(Canvas.scrollPhase([], momentum: .began) == .momentum)
    #expect(Canvas.scrollPhase([], momentum: .changed) == .momentum)
    #expect(Canvas.scrollPhase([], momentum: .ended) == .momentumEnded)
}

@Test @MainActor func momentumKeepsTheTargetChosenAtGestureStart() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    let canvas = harness.canvas
    // A gesture that starts over empty canvas stays on the canvas as it slides over the active page.
    #expect(canvas.routeScroll(phase: .began, momentum: [], overActivePage: false, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(canvas.routeScroll(phase: .changed, momentum: [], overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(canvas.routeScroll(phase: .ended, momentum: [], overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(canvas.routeScroll(phase: [], momentum: .changed, overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(canvas.routeScroll(phase: [], momentum: .ended, overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    // A plain gesture over the active page still pans the canvas; ⌥ at gesture start scrolls the page.
    #expect(canvas.routeScroll(phase: .began, momentum: [], overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    #expect(canvas.routeScroll(phase: [], momentum: .ended, overActivePage: true, pageModifier: false, zoomModifier: false) == .canvas)
    // A ⌥ gesture over the page keeps scrolling it after ⌥ is released, even with zoom held only for its own events.
    #expect(canvas.routeScroll(phase: .began, momentum: [], overActivePage: true, pageModifier: true, zoomModifier: false) == .page)
    #expect(canvas.routeScroll(phase: .changed, momentum: [], overActivePage: true, pageModifier: false, zoomModifier: true) == .canvas)
    #expect(canvas.routeScroll(phase: .changed, momentum: [], overActivePage: false, pageModifier: false, zoomModifier: false) == .page)
    #expect(canvas.routeScroll(phase: [], momentum: [], overActivePage: false, pageModifier: false, zoomModifier: false) == .canvas)
}

@Test @MainActor func wheelOverActivePagePansCanvasUnlessOptionHeld() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    select(harness)
    try #require(harness.canvas.frames["a"]).isReady = true
    let point = NSPoint(x: 100, y: 150)
    func wheel(_ flags: CGEventFlags) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
        cg.flags = flags
        return try #require(NSEvent(cgEvent: cg))
    }
    let start = harness.canvas.worldBounds
    #expect(harness.canvas.routeScrollEvent(try wheel([]), at: point) == nil)
    let panned = harness.canvas.worldBounds
    #expect(panned != start)
    _ = harness.canvas.routeScrollEvent(try wheel(.maskAlternate), at: point)
    #expect(harness.canvas.worldBounds == panned)
}

@Test @MainActor func arrowKeysAreIgnoredDuringADrag() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    harness.drag(from: NSPoint(x: 100, y: 150), to: NSPoint(x: 200, y: 150), release: false)
    let undoManager = try #require(harness.window.undoManager)
    harness.canvas.keyDown(with: try key(124, window: harness.window))
    #expect(harness.moves.isEmpty)
    #expect(!undoManager.canUndo)
    harness.send(.leftMouseUp, at: NSPoint(x: 200, y: 150))
    #expect(harness.moves == [["a": Point(x: 100, y: 0)]])
}

@Test @MainActor func scrollLockResetsWhenTheSelectionChanges() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    let canvas = harness.canvas
    select(harness)
    #expect(canvas.routeScroll(phase: .began, momentum: [], overActivePage: true, pageModifier: true, zoomModifier: false) == .page)
    select(harness, at: NSPoint(x: 500, y: 600))
    #expect(canvas.routeScroll(phase: .changed, momentum: [], overActivePage: false, pageModifier: false, zoomModifier: false) == .canvas)
}

@Test func frameIntervalLogCountsHitchesOncePerSecond() {
    var log = FrameIntervalLog()
    #expect(log.record(10.0) == nil)
    #expect(log.record(10.016) == nil)
    // 50ms is a hitch; 20ms is not.
    #expect(log.record(10.066) == nil)
    #expect(log.record(10.086) == nil)
    #expect(log.record(11.0) == "[frame] hitches=2 frames=4")
    #expect(log.record(11.016) == nil)
    #expect(log.record(12.0) == "[frame] hitches=1 frames=2")
}

@Test @MainActor func pointerDownCommitsPendingZoom() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var settled: [Viewport] = []
    harness.canvas.onViewportSettled = { settled.append($0) }
    let before = harness.canvas.worldBounds
    harness.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    #expect(harness.canvas.worldBounds == before)
    #expect(settled.isEmpty)
    harness.send(.leftMouseDown, at: NSPoint(x: 900, y: 650))
    #expect(harness.canvas.worldBounds == NSRect(x: 0, y: 0, width: before.width / 2, height: before.height / 2))
    #expect(settled == [Viewport(x: 0, y: 0, scale: 2)])
    #expect(CATransform3DIsIdentity(harness.canvas.zoomHost.layer?.sublayerTransform ?? CATransform3DMakeScale(0, 0, 0)))
}

@Test @MainActor func pinchEndCommitsAndSettles() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var settled: [Viewport] = []
    harness.canvas.onViewportSettled = { settled.append($0) }
    harness.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    harness.canvas.magnify(by: 0, at: NSPoint(x: 0, y: 0), phase: .ended)
    #expect(harness.canvas.worldBounds.width == 500)
    #expect(settled == [Viewport(x: 0, y: 0, scale: 2)])
}

@Test @MainActor func pendingZoomOverlayAndHitTestUseLiveViewport() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    select(harness)
    let before = harness.canvas.overlay.selectionBounds
    harness.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    // The committed world is scaled on the GPU: frame "b" at world (600, 0) is drawn at screen (1200, 0).
    let transform = try #require(harness.canvas.zoomHost.layer?.sublayerTransform)
    #expect(CGPoint(x: 600, y: 0).applying(CATransform3DGetAffineTransform(transform)) == CGPoint(x: 1200, y: 0))
    #expect(harness.canvas.overlay.selectionBounds.width == before.width * 2)
    // Frame "b" starts at world x 600, now on screen at 1200; world x 450 (screen 900) is empty.
    #expect(harness.canvas.hitTarget(at: NSPoint(x: 700, y: 300)) == .frameContent("a"))
    #expect(harness.canvas.hitTarget(at: NSPoint(x: 900, y: 300)) == .empty)
}

@MainActor private func animatedRequest(_ harness: CanvasHarness, to target: Viewport) {
    harness.canvas.update(project: CanvasHarness.project(id: "first"), positions: [:], positionsToken: 1,
                          viewportRequest: ViewportRequest(viewport: target, animated: true, token: 2),
                          tool: .move, reloadToken: 0)
}

@Test @MainActor func animatedRequestSettlesAtTarget() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var settled: [Viewport] = []
    harness.canvas.onViewportSettled = { settled.append($0) }
    let target = Viewport(x: -200, y: -100, scale: 0.5)
    let before = harness.canvas.worldBounds
    animatedRequest(harness, to: target)
    #expect(harness.canvas.worldBounds == before)
    harness.canvas.advanceAnimation(to: 0.5)
    #expect(settled.isEmpty)
    harness.canvas.advanceAnimation(to: 1)
    #expect(settled == [target])
    #expect(harness.canvas.worldBounds == NSRect(x: 400, y: 200, width: 2000, height: 1400))
}

@Test @MainActor func inputDuringAnimationStopsAtTheLiveViewport() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var settled: [Viewport] = []
    harness.canvas.onViewportSettled = { settled.append($0) }
    let target = Viewport(x: -200, y: -100, scale: 0.5)
    animatedRequest(harness, to: target)
    harness.canvas.advanceAnimation(to: 0.5)
    harness.send(.leftMouseDown, at: NSPoint(x: 990, y: 690))
    let expected = ViewportAnimation.value(from: Viewport(x: 0, y: 0, scale: 1), to: target, size: Size(width: 1000, height: 700),
                                           fraction: ViewportAnimation.easeOut(0.5))
    #expect(settled == [expected])
    harness.canvas.advanceAnimation(to: 1)
    #expect(settled == [expected])
}

@Test @MainActor func gridHidesWhenDense() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    let canvas = harness.canvas
    canvas.update(project: CanvasHarness.project(id: "first"), positions: [:], positionsToken: 1,
                  viewportRequest: ViewportRequest(viewport: Viewport(x: 0, y: 0, scale: 0.2), animated: false, token: 2),
                  tool: .move, reloadToken: 0)
    #expect(canvas.gridLayer.isHidden)
    canvas.update(project: CanvasHarness.project(id: "first"), positions: [:], positionsToken: 1,
                  viewportRequest: ViewportRequest(viewport: Viewport(x: 0, y: 0, scale: 1), animated: false, token: 3),
                  tool: .move, reloadToken: 0)
    #expect(!canvas.gridLayer.isHidden)
}

@Test @MainActor func commandScrollZoomSettlesAfterIdle() async throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var settled: [Viewport] = []
    harness.canvas.onViewportSettled = { settled.append($0) }
    let before = harness.canvas.worldBounds
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 50, wheel2: 0, wheel3: 0))
    cg.flags = .maskCommand
    harness.canvas.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
    #expect(harness.canvas.worldBounds == before)
    #expect(settled.isEmpty)
    // Sleeping yields the main actor so the 150ms idle timer can fire.
    try await Task.sleep(for: .milliseconds(300))
    #expect(settled.count == 1)
    #expect((settled.first?.scale ?? 1) < 1)
    #expect(abs(harness.canvas.worldBounds.width - 1000 / (settled.first?.scale ?? 1)) < 1e-6)
}

@Test @MainActor func requestedAnimationKeepsTheIndicatorAtItsTarget() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    let indicator = ZoomIndicator()
    harness.canvas.zoomIndicator = indicator
    let target = Viewport(x: -200, y: -100, scale: 0.5)
    indicator.update(target)
    animatedRequest(harness, to: target)
    harness.canvas.lastIndicatorUpdate = 0
    harness.canvas.advanceAnimation(to: 0.3)
    #expect(indicator.viewport == target)
    harness.canvas.advanceAnimation(to: 1)
    #expect(indicator.viewport == target)
}

@Test @MainActor func clickOnTheActivePageDuringAPendingZoomIsNotACanvasPress() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    _ = try activateA(harness)
    harness.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    // Frame "a" content now covers screen (0, 60)–(800, 660); the press commits the zoom and goes to the page.
    harness.drag(from: NSPoint(x: 200, y: 300), to: NSPoint(x: 400, y: 300))
    #expect(!harness.canvas.isZoomPending)
    #expect(harness.moves.isEmpty)
}

@Test @MainActor func clickOnEmptyCanvasDuringAPendingZoomIsStillACanvasPress() {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    select(harness)
    harness.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    harness.send(.leftMouseDown, at: NSPoint(x: 900, y: 690))
    harness.send(.leftMouseUp, at: NSPoint(x: 900, y: 690))
    #expect(harness.selections.last == [])
}

@Test @MainActor func pinchWithoutAnEndSettlesAfterIdle() async throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var settled: [Viewport] = []
    harness.canvas.onViewportSettled = { settled.append($0) }
    harness.canvas.magnify(by: 1, at: NSPoint(x: 0, y: 0), phase: .changed)
    #expect(settled.isEmpty)
    try await Task.sleep(for: .milliseconds(250))
    #expect(settled == [Viewport(x: 0, y: 0, scale: 2)])
    #expect(!harness.canvas.isZoomPending)
}

@Test @MainActor func unhandledKeyLeavesTheAnimationRunning() throws {
    let harness = CanvasHarness()
    defer { harness.dispose() }
    var settled: [Viewport] = []
    harness.canvas.onViewportSettled = { settled.append($0) }
    select(harness, at: NSPoint(x: 500, y: 600))
    let target = Viewport(x: -200, y: -100, scale: 0.5)
    animatedRequest(harness, to: target)
    harness.canvas.advanceAnimation(to: 0.5)
    harness.canvas.keyDown(with: try key(9, chars: "x", window: harness.window))
    harness.canvas.advanceAnimation(to: 1)
    #expect(settled == [target])
}
