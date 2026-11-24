import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// One discrete edit in a large document (#228): nudging 50 layers with an arrow key, undo, redo, and releasing the mouse after a
/// drag, each timed with the SwiftUI update of the whole editor window and the Core Animation commit. Skipped unless
/// `FUDEHAND_BENCHMARK=1`; run it with `pnpm bench:native`, which builds in release.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func editBenchmark() throws {
    for frames in [10, 40, 100] {
        let store = FudehandStore(defaults: UserDefaults(suiteName: "fudehand-bench-\(UUID().uuidString)")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(store: store))
        window.orderFront(nil)
        /// Drains the main run loop (SwiftUI applies store changes from it), then lays out and draws the window.
        func settle() {
            for _ in 0..<50 where CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        store.replace(CanvasBenchmark.document(frames: frames), url: nil)
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)); settle() }
        let canvas = try #require(store.canvas)
        window.makeFirstResponder(canvas)

        // The 50 child layers of the topmost frame, which the layers panel lists first.
        let top = "f\(frames - 1)"
        store.setSelection(Set((0..<50).map { "\(top)c\($0)" }))
        settle()

        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false,
                                     keyCode: 124)!
        for _ in 0..<4 { canvas.keyDown(with: right); settle() }
        let nudge = CanvasBenchmark.time(20) { _ in
            canvas.keyDown(with: right)
            settle()
        }
        #expect(store.editor.undoName == "Move Layers")
        let undo = CanvasBenchmark.time(20) { _ in
            store.undo()
            settle()
        }
        let redo = CanvasBenchmark.time(20) { _ in
            store.redo()
            settle()
        }

        // Press a selected layer and drag the whole selection with real pointer events; only the release is timed.
        var release = 0.0
        for run in 0..<24 {
            let viewport = canvas.liveViewport
            let rect = try #require(store.index.worldRect("\(top)c1"))
            let point = NSPoint(x: (rect.x + 15) * viewport.scale + viewport.x, y: (rect.y + 20) * viewport.scale + viewport.y)
            func send(_ type: NSEvent.EventType, _ at: NSPoint) {
                let event = NSEvent.mouseEvent(with: type, location: canvas.convert(at, to: nil), modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                default: canvas.mouseUp(with: event)
                }
            }
            send(.leftMouseDown, point)
            // Alternates right and left, so the layers stay inside their frame.
            let direction = run % 2 == 0 ? 1.0 : -1.0
            for step in 1...5 { send(.leftMouseDragged, NSPoint(x: point.x + direction * Double(step), y: point.y)) }
            // Draws the drag without running the run loop, which would end the gesture as the window is not key.
            window.displayIfNeeded()
            CATransaction.flush()
            let end = NSPoint(x: point.x + direction * 5, y: point.y)
            let start = CFAbsoluteTimeGetCurrent()
            send(.leftMouseUp, end)
            settle()
            if run >= 4 { release += (CFAbsoluteTimeGetCurrent() - start) * 1000 / 20 }
        }
        #expect(store.selection.count == 50)
        #expect(store.editor.undoName == "Move Layers")

        print(String(format: "[bench] layers=%d nudge50=%.2fms undo=%.2fms redo=%.2fms dragRelease=%.2fms",
                     store.document.nodeCount, nudge, undo, redo, release))
        window.contentView = nil
        window.close()
    }
}

/// Dragging a layer inside a main component (#256): the main component is a frame of 50 layers with 50 instances, so every drag
/// event syncs 50 instances. `instances=0` is the same document with plain frames in place of the instances, for comparison.
/// Times a drag event with real pointer events, the store's share of one (apply the move, sync the canvas), and the release.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func editBenchmarkComponentDrag() throws {
    for withInstances in [false, true] {
        var document = CanvasBenchmark.document(frames: 51)
        if withInstances {
            document.nodes[0].component = true
            var existing = document.allIDs()
            for index in 1...50 {
                var instance = ComponentSync.makeInstance(of: document.nodes[0], existing: &existing)
                instance.x = document.nodes[index].x
                instance.y = document.nodes[index].y
                document.nodes[index] = instance
            }
        }
        let h = CanvasHarness(document: document)
        defer { h.dispose() }

        // Press the second layer of the main component (a rectangle at 48, 20 in it) and drag it to and fro with snapping on.
        let point = NSPoint(x: 63, y: 140)
        h.send(.leftMouseDown, at: point)
        let drag = CanvasBenchmark.time(200) { run in
            h.send(.leftMouseDragged, at: NSPoint(x: point.x + 4 + Double(run % 7), y: point.y))
        }
        h.send(.leftMouseUp, at: point)
        #expect(h.store.selection == ["f0c1"])
        #expect(h.store.editor.undoName == "Move Layers")
        if withInstances { #expect(h.store.editor.document.nodes[50].children[1].x == h.node("f0c1")?.x) }

        // The store's share of a drag event: apply the move (and sync the instances), then sync the canvas.
        let rect = try #require(h.store.index.worldRect("f0c1"))
        h.store.canvasBeginGesture("Move Layers")
        let move = CanvasBenchmark.time(200) { run in h.store.canvasMove(["f0c1": Point(x: rect.x + Double(run % 7), y: rect.y)]) }
        h.store.canvasEndGesture()

        // Releasing a one-event drag: the end of the gesture publishes the document to the panels.
        let release = CanvasBenchmark.time(20) { run in
            h.store.canvasBeginGesture("Move Layers")
            h.store.canvasMove(["f0c1": Point(x: rect.x + Double(run % 2), y: rect.y)])
            h.store.canvasEndGesture()
        }

        print(String(format: "[bench] layers=%d instances=%d componentDragEvent=%.2fms componentCanvasMove=%.2fms componentRelease=%.2fms",
                     h.store.editor.document.nodeCount, withInstances ? 50 : 0, drag, move, release))
    }
}
