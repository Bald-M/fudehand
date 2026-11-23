import AppKit
import FudehandCore

/// Counts display-link frames and those whose interval exceeds 25ms; reports once per second.
struct FrameIntervalLog {
    static let hitchThreshold = 0.025
    private var last: CFTimeInterval?
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0

    /// Records one frame timestamp; returns the report line when a second has elapsed.
    mutating func record(_ timestamp: CFTimeInterval) -> String? {
        guard let last else {
            self.last = timestamp
            windowStart = timestamp
            return nil
        }
        self.last = timestamp
        frames += 1
        if timestamp - last > Self.hitchThreshold { hitches += 1 }
        guard timestamp - windowStart >= 1 else { return nil }
        defer { windowStart = timestamp; frames = 0; hitches = 0 }
        return "[frame] hitches=\(hitches) frames=\(frames)"
    }
}

/// A running viewport transition; `start` is in `CACurrentMediaTime()` seconds.
struct ViewportAnimationRun {
    let from: Viewport
    let to: Viewport
    let start: CFTimeInterval
}

/// Viewport rendering: pans move `world.bounds`; zooms (pinch, Command-scroll, animation) are shown as a GPU
/// transform of the committed world and committed to `world.bounds` once they settle.
extension FudehandCanvasView {
    static let frameLogEnabled = ProcessInfo.processInfo.environment["FUDEHAND_FRAME_LOG"] == "1"
    static let indicatorInterval = 1.0 / 30

    var isZoomPending: Bool { committedViewport != liveViewport }
    var worldBounds: NSRect { world.bounds }

    /// Lays out the layers for the committed and live viewports.
    func applyViewport() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomHost.frame = bounds
        world.frame = zoomHost.bounds
        overlay.frame = bounds
        let c = committedViewport
        let committedBounds = NSRect(x: -c.x / c.scale, y: -c.y / c.scale, width: bounds.width / c.scale, height: bounds.height / c.scale)
        if world.bounds != committedBounds { world.bounds = committedBounds }
        zoomHost.layer?.sublayerTransform = zoomTransform()
        gridLayer.update(viewport: liveViewport, bounds: bounds)
        // A few points of margin for soft edges that reach past the paint bounds' estimate.
        renderer.visibleRect = visibleWorldRect.insetBy(dx: -4 / liveViewport.scale, dy: -4 / liveViewport.scale)
        updateStandIns()
        CATransaction.commit()
        refreshOverlay()
        if viewMoving { scheduleBitmaps(restart: false) }
    }

    /// The part of the world the live viewport shows.
    var visibleWorldRect: CGRect {
        let v = liveViewport
        return CGRect(x: -v.x / v.scale, y: -v.y / v.scale, width: bounds.width / v.scale, height: bounds.height / v.scale)
    }

    /// While the view moves, top-level layers with a bitmap of them as they are now are drawn as it, even one drawn at another
    /// zoom (stretched until it is drawn again): any bitmap is far cheaper to show than the live layers.
    func updateStandIns() {
        renderer.standIns = viewMoving ? bitmaps.current(document.nodes) : [:]
    }

    /// Queues drawing the missing bitmaps. `restart` (after an edit or a settled view) waits for a pause first, so a drag
    /// does not redraw the bitmap of the frame it edits on every event.
    func scheduleBitmaps(restart: Bool) {
        scheduleBitmaps(after: restart ? Self.bitmapPause : 0, replacing: restart)
    }

    private func scheduleBitmaps(after delay: TimeInterval, replacing: Bool) {
        if let pending = bitmapWork {
            guard replacing else { return }
            pending.cancel()
        }
        let work = DispatchWorkItem { [weak self] in self?.drawNextBitmap() }
        bitmapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static let bitmapPause = 0.25
    /// Starting a bitmap still costs the main thread its layers (about 10 ms for a phone screen of a few hundred layers):
    /// after one took t, the next waits 3 t, so bitmaps take at most a quarter of the main thread.
    static let bitmapSpacing = 3.0

    /// Records a scroll, click, drag, or key press: bitmaps are not started until input pauses.
    func noteInput() { lastInput = CACurrentMediaTime() }

    private func drawNextBitmap() {
        bitmapWork = nil
        // The bitmap being drawn queues the next when it is done.
        guard window != nil, !bitmaps.drawing else { return }
        // While the view moves only bitmaps that are missing altogether are drawn (see `drawNext`), and those are worth a few
        // milliseconds of the main thread even mid-gesture: the layer is composited live until then.
        let quiet = CACurrentMediaTime() - lastInput
        guard viewMoving || quiet >= inputPause else { return scheduleBitmaps(after: inputPause - quiet, replacing: false) }
        // Bitmaps cover the view and half a view around it, where a pan goes next.
        let visible = visibleWorldRect
        let near = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 2)
        var spent: CFTimeInterval = 0
        guard let started = bitmaps.drawNext(document.nodes, near: near, scale: renderer.contentsScale, onlyMissing: viewMoving, finished: { [weak self] in
            guard let self else { return }
            if self.viewMoving { self.updateStandIns() }
            self.scheduleBitmaps(after: spent * Self.bitmapSpacing, replacing: false)
        }) else { return }
        spent = started
    }

    /// Maps the committed world rendering onto the live viewport: screen' = k·screen + (live − k·committed).
    private func zoomTransform() -> CATransform3D {
        guard isZoomPending, let layer = zoomHost.layer else { return CATransform3DIdentity }
        let live = liveViewport, committed = committedViewport
        let k = live.scale / committed.scale
        let map = CATransform3DConcat(CATransform3DMakeScale(k, k, 1),
                                      CATransform3DMakeTranslation(live.x - k * committed.x, live.y - k * committed.y, 0))
        // A sublayer transform applies about the layer's anchor point.
        let ax = layer.bounds.minX + layer.anchorPoint.x * layer.bounds.width
        let ay = layer.bounds.minY + layer.anchorPoint.y * layer.bounds.height
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(ax, ay, 0), map),
                                   CATransform3DMakeTranslation(-ax, -ay, 0))
    }

    /// Shows `next`. A zoom, or any change while a zoom is pending, stays a transform; a pan moves the world directly.
    func setLiveViewport(_ next: Viewport, zooming: Bool) {
        let transform = zooming || isZoomPending
        viewMoving = true
        liveViewport = next
        if !transform { committedViewport = next }
        applyViewport()
        // A requested animation's target is already on the indicator; intermediate frames would make it flicker.
        if animation == nil { updateIndicator(force: false) }
    }

    /// Commits the live viewport to `world.bounds` and reports it.
    func settleViewport() {
        committedViewport = liveViewport
        viewMoving = false
        applyViewport()
        updateIndicator(force: true)
        updateContentsScale()
        scheduleBitmaps(restart: true)
        host?.canvasViewportSettled(liveViewport)
        // The layers' VoiceOver frames moved.
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Wheel events have no end marker, so a pause settles the viewport.
    func settleSoon() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleViewport() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Called before pointer and key input: stops an animation where it is and settles any pending zoom.
    func commitPendingZoom() {
        let wasAnimating = animation != nil
        stopAnimation()
        guard isZoomPending || wasAnimating else { return }
        settleWork?.cancel()
        settleViewport()
    }

    /// Applies a store request: animated ones run from the live viewport, unless the system asks to reduce motion;
    /// others jump without reporting back.
    func apply(_ request: ViewportRequest) {
        stopAnimation()
        settleWork?.cancel()
        if request.animated, !reduceMotion(), window != nil, bounds.width > 0, bounds.height > 0 {
            animation = ViewportAnimationRun(from: liveViewport, to: request.viewport, start: CACurrentMediaTime())
            updateDisplayLink()
        } else {
            liveViewport = request.viewport
            committedViewport = request.viewport
            viewMoving = false
            applyViewport()
            updateIndicator(force: true)
            updateContentsScale()
            scheduleBitmaps(restart: true)
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    func stopAnimation() {
        guard animation != nil else { return }
        animation = nil
        updateDisplayLink()
    }

    /// Moves the running animation to `fraction` of its duration (linear time; easing is applied here).
    func advanceAnimation(to fraction: Double) {
        guard let run = animation else { return }
        guard fraction < 1 else {
            stopAnimation()
            setLiveViewport(run.to, zooming: true)
            settleViewport()
            return
        }
        let size = Size(width: bounds.width, height: bounds.height)
        setLiveViewport(ViewportAnimation.value(from: run.from, to: run.to, size: size, fraction: ViewportAnimation.easeOut(fraction)),
                        zooming: true)
    }

    /// The toolbar label follows live changes at most 30 times a second; settling always updates it.
    private func updateIndicator(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastIndicatorUpdate >= Self.indicatorInterval else { return }
        lastIndicatorUpdate = now
        zoomIndicator?.update(liveViewport)
    }

    /// Runs the display link only while animating or logging frames, and only in a window.
    func updateDisplayLink() {
        let needed = window != nil && (Self.frameLogEnabled || animation != nil)
        if needed, activeDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            activeDisplayLink = link
            frameLog = FrameIntervalLog()
        } else if !needed, let link = activeDisplayLink {
            link.invalidate()
            activeDisplayLink = nil
        }
    }

    func stopDisplayLink() {
        activeDisplayLink?.invalidate()
        activeDisplayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if Self.frameLogEnabled, let line = frameLog.record(link.timestamp) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        if let run = animation {
            advanceAnimation(to: (link.targetTimestamp - run.start) / ViewportAnimation.duration)
        }
    }
}
