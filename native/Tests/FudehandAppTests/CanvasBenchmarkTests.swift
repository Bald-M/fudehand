import AppKit
import Foundation
import Metal
import QuartzCore
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Drag and hover cost on large documents (#52). Skipped unless `FUDEHAND_BENCHMARK=1`; run it with `pnpm bench:native`,
/// which builds in release.
enum CanvasBenchmark {
    static let enabled = ProcessInfo.processInfo.environment["FUDEHAND_BENCHMARK"] == "1"

    /// `frames` top-level frames, ten per row, each holding 50 children; every fifth child is text. With `effects`, every tenth
    /// child (10% of the layers) carries a Noise, a Texture, a Glass, a Shader, and a 3D transform, the gate of ADR 0012.
    static func document(frames: Int, effects: Bool = false) -> DesignDocument {
        DesignDocument(nodes: (0..<frames).map { index in
            var frame = DesignNode(id: "f\(index)", type: .frame, name: "Frame \(index)",
                                   x: Double(index % 10) * 500, y: Double(index / 10) * 400, width: 400, height: 300)
            frame.fill = .white
            frame.children = (0..<50).map { child in
                let x = 10 + Double(child % 10) * 38, y = 20 + Double(child / 10) * 52
                var node = DesignNode(id: "f\(index)c\(child)", type: child % 5 == 0 ? .text : .rectangle, x: x, y: y, width: 30, height: 40)
                if node.type == .text { node.text = DesignText(content: "Label \(child)", fontSize: 12) } else { node.fill = .black }
                if effects, child % 10 == 1 { node.effects = advancedEffects }
                return node
            }
            return frame
        })
    }

    static let advancedEffects: [DesignEffect] = {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><circle cx="4" cy="4" r="2"/></svg>"#.utf8)
        return [DesignEffect(type: .noise), DesignEffect(type: .texture, size: 8, texture: svg), DesignEffect(type: .glass),
                DesignEffect(type: .shader), DesignEffect(type: .transform3D, rotateY: 20)]
    }()

    /// Average milliseconds per run.
    static func time(_ runs: Int, _ body: (Int) -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        for run in 0..<runs { body(run) }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(runs)
    }
}

@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func canvasDragAndHoverBenchmark() {
    for frames in [10, 40, 100] { for effects in [false, true] {
        let document = CanvasBenchmark.document(frames: frames, effects: effects)
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

        print(String(format: "[bench] layers=%d effects=%@ dragEvent=%.2fms canvasMove=%.2fms rendererSync=%.2fms hoverHit=%.3fms",
                     document.nodeCount, effects ? "10%" : "none", drag, move, sync, hover))
    } }
}

/// Pan compositing cost (#241): Core Animation's GPU time for each frame of a pan, rendered offscreen with `CARenderer` the way
/// the window server composites the canvas. *live* draws every top-level layer as it is (the canvas before #241); *moving* is
/// what the canvas shows while the view moves: layers off screen left out and frames with effects drawn as their bitmaps.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func canvasPanCompositeBenchmark() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    for frames in [40, 100] { for effects in [false, true] {
        let document = CanvasBenchmark.document(frames: frames, effects: effects)
        let h = CanvasHarness(document: document)
        defer { h.dispose() }
        let start = Viewport(x: 0, y: 0, scale: 0.5)
        h.request(start)
        let size = h.canvas.bounds.size
        // Bitmaps are drawn while the canvas is idle; wait for those around the view.
        let near = h.canvas.visibleWorldRect.insetBy(dx: -size.width, dy: -size.height)
        let wanted = document.nodes.filter { node in
            guard CanvasBitmaps.wanted(node), let paint = node.paintBounds else { return false }
            return CGRect(x: node.x + paint.x, y: node.y + paint.y, width: paint.width, height: paint.height).intersects(near)
        }
        for _ in 0..<500 where h.canvas.bitmaps.current(wanted).count < wanted.count {
            try await Task.sleep(for: .milliseconds(20))
        }
        // What drawing one bitmap costs the main thread (a frame of 50 layers, rendered offscreen and read back).
        let draws = CanvasBitmaps()
        let draw = CanvasBenchmark.time(wanted.count) { _ in
            _ = draws.drawNext(wanted, near: near, scale: h.canvas.renderer.contentsScale)
        }

        // The renderer's tree on a stage of its own: a layer can be drawn by one renderer only.
        let content = h.canvas.renderer.root
        content.removeFromSuperlayer()
        let stage = CALayer()
        stage.isGeometryFlipped = true
        stage.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        let world = CALayer()
        world.anchorPoint = .zero
        world.frame = stage.bounds
        stage.addSublayer(world)
        world.addSublayer(content)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(stage.bounds.width),
                                                                  height: Int(stage.bounds.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let compositor = CARenderer(mtlTexture: try #require(device.makeTexture(descriptor: descriptor)),
                                    options: [kCARendererMetalCommandQueue: queue])
        compositor.layer = stage
        compositor.bounds = stage.bounds

        /// Pans 120 frames and returns the 95th-percentile milliseconds per frame.
        func pan(live: Bool) -> Double {
            var times: [Double] = []
            var viewport = start
            for step in 0..<125 {
                viewport.x += step / 30 % 2 == 0 ? -8.3 : 8.3
                viewport.y -= 3.1
                h.canvas.setLiveViewport(viewport, zooming: false)
                if live { h.canvas.renderer.visibleRect = nil; h.canvas.renderer.standIns = [:] }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                world.sublayerTransform = CATransform3DMakeScale(2 * viewport.scale, 2 * viewport.scale, 1)
                world.bounds = CGRect(x: -viewport.x * 2, y: -viewport.y * 2, width: stage.bounds.width, height: stage.bounds.height)
                CATransaction.commit()
                CATransaction.flush()
                let begin = CACurrentMediaTime()
                compositor.beginFrame(atTime: begin, timeStamp: nil)
                compositor.addUpdate(compositor.bounds)
                compositor.render()
                compositor.endFrame()
                let fence = queue.makeCommandBuffer()!
                fence.commit()
                fence.waitUntilCompleted()
                // The first frames warm caches up.
                if step >= 5 { times.append((CACurrentMediaTime() - begin) * 1000) }
            }
            h.canvas.settleViewport()
            return times.sorted()[times.count * 95 / 100]
        }
        let live = pan(live: true)
        let moving = pan(live: false)
        print(String(format: "[bench] layers=%d effects=%@ panComposite p95 live=%.1fms moving=%.1fms bitmaps=%d bitmapDraw=%.1fms",
                     document.nodeCount, effects ? "10%" : "none", live, moving, wanted.count, wanted.isEmpty ? 0 : draw))
        // The gate in ADR 0012: one 60 Hz frame while the view moves.
        #expect(moving < 1000.0 / 60)
    } }
}
