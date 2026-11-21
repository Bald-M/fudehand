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
