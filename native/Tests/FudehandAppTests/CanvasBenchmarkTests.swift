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
        let wanted = h.canvas.document.nodes.filter { node in
            guard CanvasBitmaps.wanted(node), let paint = node.paintBounds else { return false }
            return CGRect(x: node.x + paint.x, y: node.y + paint.y, width: paint.width, height: paint.height).intersects(near)
        }
        for _ in 0..<500 where h.canvas.bitmaps.current(wanted).count < wanted.count {
            try await Task.sleep(for: .milliseconds(20))
        }
        // What drawing one bitmap (a frame of 50 layers) costs: the main thread's share (building its layers), and the time until
        // it is in place (rendered and read back on a background queue).
        let draws = CanvasBitmaps()
        var drawMain = 0.0, drawTotal = 0.0
        for _ in wanted {
            var done = false
            let begin = CACurrentMediaTime()
            guard let started = draws.drawNext(wanted, near: near, scale: h.canvas.renderer.contentsScale, finished: { done = true }) else { break }
            for _ in 0..<2000 where !done { try await Task.sleep(for: .milliseconds(1)) }
            drawMain += started * 1000 / Double(wanted.count)
            drawTotal += (CACurrentMediaTime() - begin) * 1000 / Double(wanted.count)
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
        print(String(format: "[bench] layers=%d effects=%@ panComposite p95 live=%.1fms moving=%.1fms bitmaps=%d bitmapMainThread=%.1fms bitmapTotal=%.1fms",
                     document.nodeCount, effects ? "10%" : "none", live, moving, wanted.count, drawMain, drawTotal))
        // The gate in ADR 0012: one 60 Hz frame while the view moves.
        #expect(moving < 1000.0 / 60)
    } }
}

/// The main thread while the canvas draws its bitmaps (#243): the whole 5100-layer document zoomed out into view, so every
/// frame with effects wants a bitmap. A heartbeat on the main thread records how long it was kept from running.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func canvasBitmapMainThreadBenchmark() async throws {
    // A test process has no window on screen: without this, App Nap delays its timers by seconds.
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Benchmark")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let document = CanvasBenchmark.document(frames: 100, effects: true)
    // One bitmap first: the first in a process also sets up Core Image's filters and text (16–36 ms, varying with the
    // machine's load), once per launch. What is measured is the steady cost of each bitmap.
    _ = try OffscreenImage(of: document.nodes[0], in: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 0.5).draw()
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    h.request(Viewport(x: 0, y: 0, scale: 0.14))
    // The nodes as the canvas holds them (laid out by the store).
    let wanted = h.canvas.document.nodes.filter(CanvasBitmaps.wanted)
    let start = CACurrentMediaTime()
    var last = start, longest = 0.0, dropped = 0
    while h.canvas.bitmaps.current(wanted).count < wanted.count, CACurrentMediaTime() - start < 60 {
        try await Task.sleep(for: .milliseconds(2))
        let now = CACurrentMediaTime()
        let gap = (now - last) * 1000
        longest = max(longest, gap)
        if gap > 1000.0 / 60 { dropped += 1 }
        last = now
    }
    #expect(h.canvas.bitmaps.current(wanted).count == wanted.count)
    print(String(format: "[bench] layers=%d bitmaps=%d allDrawn=%.2fs longestMainThreadBlock=%.1fms blocksOver16.7ms=%d",
                 document.nodeCount, wanted.count, CACurrentMediaTime() - start, longest, dropped))
    // Each bitmap holds the main thread for its layers only (about 3.5 ms here): at most one frame is dropped to the system,
    // and never two in a row.
    #expect(dropped <= 1)
    #expect(longest < 2000.0 / 60)
}

/// The canvas at rest (#245): with every frame of the 5100-layer document in view, how long Core Animation takes to composite
/// the whole canvas again, which the window server does whenever anything on it changes (a selection box, a hover outline).
/// *live* draws the top-level layers as they are; *rest* is what the canvas shows once their bitmaps are drawn.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func canvasRestCompositeBenchmark() async throws {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Benchmark")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let h = CanvasHarness(document: CanvasBenchmark.document(frames: 100, effects: true))
    defer { h.dispose() }
    let viewport = Viewport(x: 0, y: 0, scale: 0.14)
    h.request(viewport)
    let wanted = h.canvas.document.nodes.filter(CanvasBitmaps.wanted)
    for _ in 0..<1500 where h.canvas.bitmaps.current(wanted, minimumScale: h.canvas.renderer.contentsScale).count < wanted.count {
        try await Task.sleep(for: .milliseconds(20))
    }
    let size = h.canvas.bounds.size
    let content = h.canvas.renderer.root
    content.removeFromSuperlayer()
    let stage = CALayer()
    stage.isGeometryFlipped = true
    stage.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
    let world = CALayer()
    world.anchorPoint = .zero
    world.bounds = CGRect(origin: .zero, size: size)
    world.position = CGPoint(x: viewport.x * 2, y: viewport.y * 2)
    world.transform = CATransform3DMakeScale(2 * viewport.scale, 2 * viewport.scale, 1)
    stage.addSublayer(world)
    world.addSublayer(content)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(stage.bounds.width),
                                                              height: Int(stage.bounds.height), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    let compositor = CARenderer(mtlTexture: try #require(device.makeTexture(descriptor: descriptor)),
                                options: [kCARendererMetalCommandQueue: queue])
    compositor.layer = stage
    compositor.bounds = stage.bounds

    /// Composites the whole canvas 25 times and returns the 95th-percentile milliseconds.
    func composite() -> Double {
        CATransaction.flush()
        var times: [Double] = []
        for step in 0..<25 {
            let begin = CACurrentMediaTime()
            compositor.beginFrame(atTime: begin, timeStamp: nil)
            compositor.addUpdate(compositor.bounds)
            compositor.render()
            compositor.endFrame()
            let fence = queue.makeCommandBuffer()!
            fence.commit()
            fence.waitUntilCompleted()
            if step >= 3 { times.append((CACurrentMediaTime() - begin) * 1000) }
        }
        return times.sorted()[times.count * 95 / 100]
    }
    let rest = composite()
    let standIns = h.canvas.renderer.standIns
    h.canvas.renderer.standIns = [:]
    let live = composite()
    print(String(format: "[bench] layers=5100 framesInView=100 restComposite p95 live=%.1fms rest=%.1fms bitmaps=%d",
                 live, rest, standIns.count))
    #expect(standIns.count == wanted.count)
    // The gate in ADR 0012: one 60 Hz frame at rest.
    #expect(rest < 1000.0 / 60)
}

/// Opening a large design with glass and zooming out to all of it (#247): 200 phone-sized frames of 70 layers, each holding 5
/// glass layers, 2 layer blurs, and 8 drop shadows, all in view at 5%. *open* is how long the main thread took to show it;
/// *composite* is how long Core Animation takes to composite the canvas as it then stands, which the window server does whenever
/// anything on it changes, until the bitmaps are drawn; then the main thread is timed with a heartbeat until they are.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func canvasOpenLargeDesignBenchmark() async throws {
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Benchmark")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let document = DesignDocument(nodes: (0..<200).map { index in
        var frame = DesignNode(id: "f\(index)", type: .frame, name: "Screen \(index)",
                               x: Double(index % 15) * 450, y: Double(index / 15) * 900, width: 390, height: 844)
        frame.fill = .white
        frame.children = (0..<70).map { child in
            let x = 10 + Double(child % 7) * 54, y = 20 + Double(child / 7) * 80
            var node = DesignNode(id: "f\(index)c\(child)", type: child % 5 == 0 ? .text : .rectangle, x: x, y: y, width: 48, height: 64)
            if node.type == .text { node.text = DesignText(content: "Label \(child)", fontSize: 12) } else { node.fill = .black }
            switch child % 14 {
            case 1, 3, 5, 7, 9: node.effects = [DesignEffect(type: .glass)]
            case 11, 13: node.effects = [DesignEffect(type: .layerBlur, radius: 12)]
            default: if child % 5 != 0 { node.effects = [DesignEffect(type: .dropShadow, radius: 8)] }
            }
            return node
        }
        return frame
    })
    // The first offscreen render in a process sets up Core Image's filters and text, once per launch.
    _ = try OffscreenImage(of: document.nodes[0], in: CGRect(x: 0, y: 0, width: 390, height: 844), scale: 0.5).draw()
    let begin = CACurrentMediaTime()
    let h = CanvasHarness(document: document)
    defer { h.dispose() }
    let viewport = Viewport(x: 20, y: 20, scale: 0.05)
    h.request(viewport)
    let open = (CACurrentMediaTime() - begin) * 1000

    // The canvas as it stands right after opening, composited offscreen at 2 pixels per point.
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let size = h.canvas.bounds.size
    let content = h.canvas.renderer.root
    let home = try #require(content.superlayer)
    content.removeFromSuperlayer()
    let stage = CALayer()
    stage.isGeometryFlipped = true
    stage.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
    let world = CALayer()
    world.anchorPoint = .zero
    world.bounds = CGRect(origin: .zero, size: size)
    world.position = CGPoint(x: viewport.x * 2, y: viewport.y * 2)
    world.transform = CATransform3DMakeScale(2 * viewport.scale, 2 * viewport.scale, 1)
    stage.addSublayer(world)
    world.addSublayer(content)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(stage.bounds.width),
                                                              height: Int(stage.bounds.height), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    let compositor = CARenderer(mtlTexture: try #require(device.makeTexture(descriptor: descriptor)),
                                options: [kCARendererMetalCommandQueue: queue])
    compositor.layer = stage
    compositor.bounds = stage.bounds
    CATransaction.flush()
    var times: [Double] = []
    for _ in 0..<4 {
        let start = CACurrentMediaTime()
        compositor.beginFrame(atTime: start, timeStamp: nil)
        compositor.addUpdate(compositor.bounds)
        compositor.render()
        compositor.endFrame()
        let fence = queue.makeCommandBuffer()!
        fence.commit()
        fence.waitUntilCompleted()
        times.append((CACurrentMediaTime() - start) * 1000)
    }
    // The first composite sets the layers up; the median of the rest.
    let composite = times.dropFirst().sorted()[1]
    compositor.layer = nil
    content.removeFromSuperlayer()
    home.addSublayer(content)

    let wanted = h.canvas.document.nodes.filter(CanvasBitmaps.wanted)
    let start = CACurrentMediaTime()
    var last = start, longest = 0.0, dropped = 0
    while h.canvas.bitmaps.current(wanted).count < wanted.count, CACurrentMediaTime() - start < 120 {
        try await Task.sleep(for: .milliseconds(2))
        let now = CACurrentMediaTime()
        let gap = (now - last) * 1000
        longest = max(longest, gap)
        if gap > 1000.0 / 60 { dropped += 1 }
        last = now
    }
    #expect(h.canvas.bitmaps.current(wanted).count == wanted.count)
    print(String(format: "[bench] layers=%d framesInView=%d open=%.0fms openComposite=%.1fms allDrawn=%.2fs longestMainThreadBlock=%.1fms blocksOver16.7ms=%d",
                 document.nodeCount, wanted.count, open, composite, CACurrentMediaTime() - start, longest, dropped))
    // Until the bitmaps are drawn, a change on the canvas is composited in tens of milliseconds, not seconds.
    #expect(composite < 50)
    #expect(longest < 250)
}

/// Opening a large phone design (#248): 226 screens of about 70 layers each (16k layers), with text whose labels repeat
/// across screens and SVG icons placed many times over, like a light and dark copy of every screen. Measures, on a cold
/// process, reading the file and the main thread's share of opening it with the editor canvas attached, fitted to all.
@Test(.enabled(if: CanvasBenchmark.enabled)) @MainActor func documentOpenBenchmark() throws {
    let icons = (0..<40).map { index in
        Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M\##(index % 12) 2h\##(8 + index % 9)v\##(6 + index % 7)H4z" fill="#\##(String(format: "%06X", index * 40_503))"/></svg>"##.utf8)
    }
    let labels = (0..<60).map { "Shared label \($0)" }
    let document = DesignDocument(nodes: (0..<226).map { screen in
        var frame = DesignNode(id: "s\(screen)", type: .frame, name: "Screen \(screen)",
                               x: Double(screen % 12) * 470, y: Double(screen / 12) * 964, width: 390, height: 844)
        frame.fill = .white
        frame.children = (0..<70).map { child in
            let id = "s\(screen)c\(child)", y = 20 + Double(child) * 11
            switch child % 7 {
            case 0, 1, 2:
                var node = DesignNode(id: id, type: .text, x: 16, y: y, width: 300, height: 20)
                // Most labels repeat on other screens; one in nine is the screen's own.
                let content = child % 9 == 0 ? "Screen \(screen) item \(child)" : labels[(screen + child) % labels.count]
                node.text = DesignText(content: content, fontSize: child % 2 == 0 ? 14 : 12, autoResize: child % 2 == 0 ? .widthAndHeight : .height)
                return node
            case 3:
                let side = [14.0, 18, 24][child % 3]
                var node = DesignNode(id: id, type: .image, x: 340, y: y, width: side, height: side)
                node.image = DesignImage(data: icons[(screen * 7 + child) % icons.count])
                return node
            default:
                var node = DesignNode(id: id, type: child % 13 == 0 ? .ellipse : .rectangle, x: 16, y: y, width: 358, height: 8)
                node.fill = .black
                return node
            }
        }
        return frame
    })
    let data = try document.encoded()
    let h = CanvasHarness()
    defer { h.dispose() }
    var start = CACurrentMediaTime()
    let decoded = try DesignDocument.decode(data)
    let read = (CACurrentMediaTime() - start) * 1000
    start = CACurrentMediaTime()
    h.store.replace(decoded, url: nil)
    let open = (CACurrentMediaTime() - start) * 1000
    start = CACurrentMediaTime()
    CATransaction.flush()
    let commit = (CACurrentMediaTime() - start) * 1000
    print(String(format: "[bench] layers=%d documentOpen read=%.0fms mainThread=%.0fms commit=%.0fms",
                 decoded.nodeCount, read, open, commit))
    #expect(h.canvas.renderer.layerCount == decoded.nodeCount)
    // About 400–600 ms before the text measurements were made in parallel and SVG icons parsed and rasterized once each.
    #expect(open < 300)
}
