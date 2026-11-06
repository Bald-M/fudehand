import AppKit
import AtlasCore

final class AtlasCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var zoomIndicator: ZoomIndicator?
    var onViewportSettled: ((Viewport) -> Void)?
    var onFramesMoved: (([String: Point]) -> Void)?
    var onSelectionChange: ((Set<String>) -> Void)?
    var onToolChange: ((CanvasTool) -> Void)?
    var onFocusFrame: ((String) -> Void)?
    var onSizeChange: ((CGSize) -> Void)?
    private let world = CanvasWorldView()
    private var frames: [String: PreviewFrameView] = [:]
    private var projectID: String?
    private var reloadToken: Int?
    private var positionsToken: Int?
    private var requestToken: Int?
    private(set) var tool = CanvasTool.move
    private var viewport = Viewport()
    private var positions: [String: Point] = [:]
    /// A frame is interactive (its page receives input) exactly when it is the only selected frame.
    private var selection: Set<String> = []
    private var settleWork: DispatchWorkItem?
    private var panStart: (CGPoint, Viewport)?
    private var eventMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    var spaceHeld = false
    private var lastReportedSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        world.canvas = self
        addSubview(world)
        setAccessibilityLabel("界面画布")
        setAccessibilityHelp("拖动空白平移；Command 加滚轮缩放；选择画框后用方向键移动。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        removeFocusObservers()
        guard let window else { return }
        // The Space key-up goes to whichever app or window is focused when it is released.
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseHeldInput() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseHeldInput() }
            },
        ]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .flagsChanged, .keyUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyUp, event.keyCode == 49 { self.spaceHeld = false }
            if event.type == .flagsChanged { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            if event.type == .scrollWheel, event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                self.scrollWheel(with: event)
                return nil
            }
            if event.type == .magnify {
                self.magnify(with: event)
                return nil
            }
            return event
        }
    }

    func dispose() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        removeFocusObservers()
        settleWork?.cancel()
        frames.values.forEach { $0.dispose() }
        frames.removeAll()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        focusObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func removeFocusObservers() {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
    }

    /// Clears Space panning when focus leaves, since the matching key-up will not arrive here.
    func releaseHeldInput() {
        spaceHeld = false
        if panStart != nil { endPan() }
    }

    func update(project: Project, positions: [String: Point], positionsToken: Int,
                viewportRequest: ViewportRequest, tool: CanvasTool, reloadToken: Int) {
        self.tool = tool
        var layoutChanged = false
        if projectID != project.id {
            frames.values.forEach { $0.dispose(); $0.removeFromSuperview() }
            frames.removeAll()
            projectID = project.id
            for frame in project.frames {
                let view = PreviewFrameView(frame: frame, baseURL: project.preview.baseUrl)
                view.canvas = self
                frames[frame.id] = view
                world.addSubview(view)
            }
            self.reloadToken = reloadToken
            self.positionsToken = nil
            layoutChanged = true
        }
        if self.positionsToken != positionsToken {
            self.positionsToken = positionsToken
            self.positions = positions
            layoutChanged = true
        }
        if layoutChanged {
            for frame in project.frames {
                guard let view = frames[frame.id] else { continue }
                let position = self.positions[frame.id] ?? Point(x: frame.x, y: frame.y)
                view.frame = NSRect(x: position.x, y: position.y, width: frame.width,
                                    height: frame.height + CanvasGeometry.headerHeight)
            }
            setSelection([])
        }
        if self.reloadToken != reloadToken {
            frames.values.forEach { $0.reload() }
            self.reloadToken = reloadToken
        }
        if requestToken != viewportRequest.token {
            requestToken = viewportRequest.token
            viewport = viewportRequest.viewport
            applyViewport()
            zoomIndicator?.update(viewport)
        }
    }

    /// Reports through the store asynchronously because this can run during a SwiftUI update.
    private func setSelection(_ next: Set<String>) {
        guard next != selection else { return }
        let wasInteracting = selection.count == 1
        selection = next
        for (id, frame) in frames {
            frame.selected = next.contains(id)
            frame.interactive = next.count == 1 && next.contains(id)
        }
        if wasInteracting && next.count != 1 { window?.makeFirstResponder(self) }
        DispatchQueue.main.async { [weak self] in self?.onSelectionChange?(next) }
    }

    override func layout() {
        super.layout()
        applyViewport()
        if bounds.size != lastReportedSize, bounds.width > 0, bounds.height > 0 {
            lastReportedSize = bounds.size
            let size = bounds.size
            DispatchQueue.main.async { [weak self] in self?.onSizeChange?(size) }
        }
    }

    private func applyViewport() {
        world.frame = bounds
        world.bounds = NSRect(x: -viewport.x / viewport.scale, y: -viewport.y / viewport.scale,
                              width: bounds.width / viewport.scale, height: bounds.height / viewport.scale)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let step = max(12, 32 * viewport.scale)
        let offsetX = viewport.x.truncatingRemainder(dividingBy: step)
        let offsetY = viewport.y.truncatingRemainder(dividingBy: step)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        var x = offsetX
        while x < bounds.width {
            var y = offsetY
            while y < bounds.height {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
                y += step
            }
            x += step
        }
    }

    func select(_ id: String) {
        if selection == [id] { frames[id]?.focusContent() } else { setSelection([id]) }
    }

    /// Leaves page interaction and returns keyboard focus to the canvas.
    func deselect() {
        setSelection([])
        window?.makeFirstResponder(self)
    }

    func focus(_ id: String) { select(id); onFocusFrame?(id) }

    func move(_ id: String, delta: CGPoint, from start: Point) {
        let point = CanvasGeometry.moveFrame(start, screenDelta: Point(x: delta.x, y: delta.y), scale: viewport.scale)
        positions[id] = point
        if let frame = frames[id] { frame.setFrameOrigin(NSPoint(x: point.x, y: point.y)) }
        onFramesMoved?([id: point])
    }

    func position(of id: String) -> Point { positions[id] ?? Point(x: 0, y: 0) }

    func beginPan(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        panStart = (convert(event.locationInWindow, from: nil), viewport)
        NSCursor.closedHand.set()
    }

    func continuePan(_ event: NSEvent) {
        guard let (start, initial) = panStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        viewport = Viewport(x: initial.x + point.x - start.x, y: initial.y + point.y - start.y, scale: initial.scale)
        applyViewport()
        zoomIndicator?.update(viewport)
    }

    func endPan() {
        panStart = nil
        NSCursor.arrow.set()
        onViewportSettled?(viewport)
    }

    /// Wheel and pinch events have no end marker, so a pause settles the viewport.
    private func settleSoon() {
        zoomIndicator?.update(viewport)
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onViewportSettled?(self.viewport)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func mouseDown(with event: NSEvent) { beginPan(event) }
    override func mouseDragged(with event: NSEvent) { continuePan(event) }
    override func mouseUp(with event: NSEvent) { endPan() }

    override func scrollWheel(with event: NSEvent) {
        // A line-based mouse wheel reports about one unit per notch; trackpads report points.
        let delta = CanvasGeometry.wheelDelta(Point(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
                                              precise: event.hasPreciseScrollingDeltas)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let point = convert(event.locationInWindow, from: nil)
            viewport = CanvasGeometry.zoomAt(viewport, point: Point(x: point.x, y: point.y),
                                             scale: viewport.scale * exp(-delta.y * 0.01))
        } else {
            viewport = Viewport(x: viewport.x + delta.x, y: viewport.y + delta.y, scale: viewport.scale)
        }
        applyViewport()
        settleSoon()
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        viewport = CanvasGeometry.zoomAt(viewport, point: Point(x: point.x, y: point.y), scale: viewport.scale * (1 + event.magnification))
        applyViewport()
        settleSoon()
    }

    override func keyDown(with event: NSEvent) {
        // WebKit may pass an unhandled key up the native responder chain after DOM
        // dispatch. The injected Escape script alone decides whether Escape exits interaction.
        if event.keyCode == 49 { spaceHeld = true; return }
        if event.keyCode == 53 { return }
        guard selection.count == 1, let id = selection.first, let position = positions[id] else { super.keyDown(with: event); return }
        let step: Double = event.modifierFlags.contains(.shift) ? 100 : 10
        var next = position
        switch event.keyCode {
        case 123: next.x -= step
        case 124: next.x += step
        case 125: next.y += step
        case 126: next.y -= step
        case 36: select(id); return
        default: super.keyDown(with: event); return
        }
        positions[id] = next
        frames[id]?.setFrameOrigin(NSPoint(x: next.x, y: next.y))
        onFramesMoved?([id: next])
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }
}

private final class CanvasWorldView: NSView {
    weak var canvas: AtlasCanvasView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? canvas : result
    }
}
