import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Drag and hover cost on large documents (#52). Skipped unless `FUDEHAND_BENCHMARK=1`; run it with `pnpm bench:native`,
/// which builds in release.
enum CanvasBenchmark {
    static let enabled = ProcessInfo.processInfo.environment["FUDEHAND_BENCHMARK"] == "1"

    /// `frames` top-level frames, ten per row, each holding 50 children; every fifth child is text.
    static func document(frames: Int) -> DesignDocument {
        DesignDocument(nodes: (0..<frames).map { index in
            var frame = DesignNode(id: "f\(index)", type: .frame, name: "Frame \(index)",
                                   x: Double(index % 10) * 500, y: Double(index / 10) * 400, width: 400, height: 300)
            frame.fill = .white
            frame.children = (0..<50).map { child in
                let x = 10 + Double(child % 10) * 38, y = 20 + Double(child / 10) * 52
                var node = DesignNode(id: "f\(index)c\(child)", type: child % 5 == 0 ? .text : .rectangle, x: x, y: y, width: 30, height: 40)
                if node.type == .text { node.text = DesignText(content: "Label \(child)", fontSize: 12) } else { node.fill = .black }
                return node
            }
            return frame
        })
    }

    /// Average milliseconds per run.
    static func time(_ runs: Int, _ body: (Int) -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        for run in 0..<runs { body(run) }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(runs)
    }
}

@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func canvasDragAndHoverBenchmark() {
    for frames in [10, 40, 100] {
        let document = CanvasBenchmark.document(frames: frames)
        let h = CanvasHarness(document: document)
        defer { h.dispose() }
        let label = NSPoint(x: 5, y: 88)
        #expect(h.canvas.hitTarget(at: label) == .label("f0"))

        // Real pointer events: press the first frame's name label and drag it, with snapping on.
        h.send(.leftMouseDown, at: label)
        let drag = CanvasBenchmark.time(200) { run in
            h.send(.leftMouseDragged, at: NSPoint(x: label.x + 4 + Double(run), y: label.y + Double(run % 7)))
        }
        h.send(.leftMouseUp, at: label)
        #expect(h.node("f0")?.x != 0)
        #expect(h.store.editor.undoName == "Move Layers")

        // The store's share of a drag event: apply the move, then sync the canvas.
        h.store.canvasBeginGesture("Move Layers")
        let move = CanvasBenchmark.time(200) { run in h.store.canvasMove(["f0": Point(x: Double(run), y: 0)]) }
        h.store.canvasEndGesture()

        var moved = document
        moved.nodes[0].x += 1
        let sync = CanvasBenchmark.time(200) { run in h.canvas.renderer.sync(run % 2 == 0 ? moved.nodes : document.nodes) }

        // Hovering a child of the last frame's neighbor row: every frame label is tested first.
        let hover = CanvasBenchmark.time(1000) { _ in _ = h.canvas.hitTarget(at: NSPoint(x: 520, y: 130)) }

        print(String(format: "[bench] layers=%d dragEvent=%.2fms canvasMove=%.2fms rendererSync=%.2fms hoverHit=%.3fms",
                     document.nodeCount, drag, move, sync, hover))
    }
}
