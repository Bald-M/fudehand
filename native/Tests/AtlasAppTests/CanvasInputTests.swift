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
