import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Waits, letting the main run loop turn, until `done` holds or a few seconds pass.
@MainActor private func turn(until done: () -> Bool) async throws {
    let start = CACurrentMediaTime()
    while !done(), CACurrentMediaTime() - start < 5 { try await Task.sleep(for: .milliseconds(1)) }
}

/// A large document is built a part at a time, the top-level layers nearest the middle of the view first, so the canvas shows
/// at once and no run loop turn holds the main thread for all of it (#248).
@Test @MainActor func aLargeDocumentIsBuiltNearestTheViewFirst() async throws {
    let document = CanvasBenchmark.document(frames: 150)
    #expect(document.nodeCount > FudehandCanvasView.buildAtOnce)
    let h = CanvasHarness()
    defer { h.dispose() }
    h.request(Viewport(x: 0, y: 100, scale: 1))
    h.store.replace(document, url: nil)
    #expect(h.canvas.renderer.layerCount < document.nodeCount)

    try await turn { h.canvas.renderer.layerCount == document.nodeCount }
    #expect(h.canvas.renderer.layerCount == document.nodeCount && h.canvas.unbuilt.isEmpty)
}

/// The first part built holds the frame at the middle of the view, not the one farthest from it.
@Test @MainActor func theFirstPartBuiltIsTheOneInView() async throws {
    let document = CanvasBenchmark.document(frames: 150)
    let h = CanvasHarness()
    defer { h.dispose() }
    h.store.replace(document, url: nil)
    // Opening fits the document to the view; this looks at its top-left corner instead, before the first part is built.
    h.request(Viewport(x: 0, y: 100, scale: 1))
    try await turn { h.canvas.renderer.layerCount > 0 }
    #expect(h.canvas.renderer.layer(for: "f0") != nil && h.canvas.renderer.layer(for: "f149") == nil)
}

/// A layer created while the document is still being built shows at once, and a deleted one is not built later.
@Test @MainActor func editsWhileALargeDocumentIsBuiltShowAtOnce() async throws {
    let document = CanvasBenchmark.document(frames: 150)
    let h = CanvasHarness()
    defer { h.dispose() }
    h.request(Viewport(x: 0, y: 100, scale: 1))
    h.store.replace(document, url: nil)
    _ = try await h.store.handleControl(.createNode(parent: nil, index: nil, node: JSONObject(["id": "new", "type": "rectangle"])))
    #expect(h.canvas.renderer.layer(for: "new") != nil)
    #expect(h.canvas.unbuilt.contains("f149"))
    _ = try await h.store.handleControl(.deleteNodes(["f149"]))
    #expect(!h.canvas.unbuilt.contains("f149"))
    try await turn { h.canvas.renderer.layerCount == h.store.editor.document.nodeCount }
    #expect(h.canvas.renderer.layerCount == h.store.editor.document.nodeCount && h.canvas.renderer.layer(for: "f149") == nil)
}

/// A document at or below the limit is built in full when it is shown, as before.
@Test @MainActor func aSmallDocumentIsBuiltAtOnce() {
    let document = CanvasBenchmark.document(frames: 100)
    #expect(document.nodeCount <= FudehandCanvasView.buildAtOnce)
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    #expect(h.canvas.renderer.layerCount == document.nodeCount)
}

/// Another document opened while a large one is still being built replaces it; nothing of the first is built later.
@Test @MainActor func aDocumentOpenedMidBuildReplacesTheRest() async throws {
    let h = CanvasHarness()
    defer { h.dispose() }
    h.store.replace(CanvasBenchmark.document(frames: 150), url: nil)
    let small = CanvasBenchmark.document(frames: 2)
    h.store.replace(small, url: nil)
    #expect(h.canvas.unbuilt.isEmpty && h.canvas.renderer.layerCount == small.nodeCount)
    try await Task.sleep(for: .milliseconds(50))
    #expect(h.canvas.renderer.layerCount == small.nodeCount)
}
