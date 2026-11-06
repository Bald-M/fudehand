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
    var onCommand: ((CanvasCommand) -> Void)?
    var onSizeChange: ((CGSize) -> Void)?
    private let world = CanvasWorldView()
    let overlay = CanvasOverlay()
    private(set) var frames: [String: PreviewFrameView] = [:]
    private var projectID: String?
    private var reloadToken: Int?
    private var positionsToken: Int?
    private var requestToken: Int?
    private(set) var tool = CanvasTool.move {
        didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var scrollRouter = ScrollRouter()
    private var viewport = Viewport()
    private var positions: [String: Point] = [:]
    /// The active frame (its page receives pointer input) is the only selected frame, once loaded.
    private var selection: Set<String> = []
    private var interaction = CanvasInteraction()
    private var hover: String?
    private var marquee: Rect?
    private var guides: [Guide] = []
    /// Set when the current gesture panned, so its end reports the settled viewport.
    private var gesturePanned = false
    private var settleWork: DispatchWorkItem?
    private var eventMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    var spaceHeld = false
    private var lastReportedSize = CGSize.zero
    var activeDisplayLink: CADisplayLink?
    var frameLog = FrameIntervalLog()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(world)
        addSubview(overlay)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        setAccessibilityLabel("界面画布")
        setAccessibilityHelp("点选画框后可直接操作；拖动空白框选；空格拖动平移；Command 加滚轮缩放；选择画框后用方向键移动。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        removeFocusObservers()
        updateDisplayLink()
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
            if event.type == .scrollWheel { return self.routeScrollEvent(event, at: point) }
            if event.type == .magnify {
                self.magnify(with: event)
                return nil
            }
            return event
        }
    }

    func dispose() {
        window?.undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        removeFocusObservers()
        settleWork?.cancel()
        stopDisplayLink()
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

    /// Clears Space panning and finishes any gesture when focus leaves, since the matching
    /// key-up or mouse-up will not arrive here. An in-progress frame drag commits where it is.
    func releaseHeldInput() {
        spaceHeld = false
        endGesture(interaction.cancel())
    }

    func update(project: Project, positions: [String: Point], positionsToken: Int,
                viewportRequest: ViewportRequest, tool: CanvasTool, reloadToken: Int) {
        self.tool = tool
        var layoutChanged = false
        if projectID != project.id {
            frames.values.forEach { $0.dispose(); $0.removeFromSuperview() }
            frames.removeAll()
            projectID = project.id
            scrollRouter = ScrollRouter()
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
        // Also runs after every project switch, which resets positionsToken.
        if self.positionsToken != positionsToken {
            window?.undoManager?.removeAllActions(withTarget: self)
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
            // Positions were replaced wholesale, so an unfinished gesture is dropped rather than committed.
            _ = interaction.cancel()
            gesturePanned = false
            hover = nil
            marquee = nil
            guides = []
            setSelection([], deferReport: true)
            refreshOverlay()
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

    /// `deferReport` is for calls made during a SwiftUI update, where the store must not change synchronously.
    private func setSelection(_ next: Set<String>, deferReport: Bool = false) {
        guard next != selection else { return }
        selection = next
        // A gesture locked to the previous active page must not carry over.
        scrollRouter = ScrollRouter()
        // Keyboard focus never stays in a page whose frame is no longer the active one.
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: world),
           activeFrameID.flatMap({ frames[$0] }).map({ !responder.isDescendant(of: $0) }) ?? true {
            window?.makeFirstResponder(self)
        }
        updateFrameAccessibility()
        refreshOverlay()
        if deferReport {
            DispatchQueue.main.async { [weak self] in self?.onSelectionChange?(next) }
        } else {
            onSelectionChange?(next)
        }
    }

    private var activeFrameID: String? {
        guard selection.count == 1, let id = selection.first, frames[id]?.isReady == true else { return nil }
        return id
    }

    func frameReadinessChanged(_ frame: PreviewFrameView) {
        if selection.contains(frame.frameID) { scrollRouter = ScrollRouter() }
        // A page that reloads or fails hides its web view, so keyboard focus must not stay inside it.
        if !frame.isReady, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: frame) {
            window?.makeFirstResponder(self)
        }
        updateFrameAccessibility()
        refreshOverlay()
    }

    private func updateFrameAccessibility() {
        let active = activeFrameID
        for (id, frame) in frames {
            frame.updateAccessibility(selected: selection.contains(id), active: id == active)
        }
    }

    /// The active page's Escape bridge: leave the page and return keyboard focus to the canvas.
    func pageRequestedExit(_ id: String) {
        guard activeFrameID == id else { return }
        setSelection([])
        window?.makeFirstResponder(self)
    }

    private func refreshOverlay() {
        overlay.render(viewport: viewport, frames: frameRects(), selection: selection, active: activeFrameID,
                       hover: hover, marquee: marquee, guides: guides)
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
        overlay.frame = bounds
        world.bounds = NSRect(x: -viewport.x / viewport.scale, y: -viewport.y / viewport.scale,
                              width: bounds.width / viewport.scale, height: bounds.height / viewport.scale)
        refreshOverlay()
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

    // MARK: Pointer input

    /// World-space frame rects including the header, keyed by frame id.
    private func frameRects() -> [String: Rect] {
        frames.mapValues { Rect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
    }

    private func interactionContext() -> InteractionContext {
        InteractionContext(viewport: viewport, frames: frameRects(), selection: selection, tool: tool, spaceHeld: spaceHeld,
                           activatable: Set(frames.filter { $0.value.isReady }.keys))
    }

    /// The topmost frame under a canvas (screen-space) point; the header is the top `headerHeight` world units.
    func hitTarget(at screen: NSPoint) -> HitTarget {
        let point = world.convert(screen, from: self)
        for case let frame as PreviewFrameView in world.subviews.reversed() where frame.frame.contains(point) {
            return point.y - frame.frame.minY < CanvasGeometry.headerHeight ? .frameHeader(frame.frameID) : .frameContent(frame.frameID)
        }
        return .empty
    }

    /// Only the active frame's page content receives the pointer, and frame controls stay clickable;
    /// everything else comes to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { hitTest(point, event: NSApp?.currentEvent) }

    /// `event` is the event being routed; Shift-clicks always come to the canvas so they toggle selection,
    /// and only button 2 counts as the middle (panning) button.
    func hitTest(_ point: NSPoint, event: NSEvent?) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let hit = hitTarget(at: local)
        switch hit {
        case .frameHeader(let id), .frameContent(let id):
            if let frame = frames[id], let control = frame.control(at: frame.convert(local, from: self)) { return control }
        case .empty:
            break
        }
        if event?.type == .leftMouseDown, event?.modifierFlags.contains(.shift) == true { return self }
        let button: PointerButton = event?.type == .otherMouseDown && event?.buttonNumber == 2 ? .middle : .primary
        if CanvasInteraction.pageReceivesPointer(hit: hit, button: button, context: interactionContext()) {
            return super.hitTest(point)
        }
        return self
    }

    private func screenPoint(_ event: NSEvent) -> (NSPoint, Point) {
        let point = convert(event.locationInWindow, from: nil)
        return (point, Point(x: point.x, y: point.y))
    }

    private func modifiers(_ event: NSEvent) -> PointerModifiers {
        var result: PointerModifiers = []
        if event.modifierFlags.contains(.shift) { result.insert(.shift) }
        if event.modifierFlags.contains(.control) { result.insert(.control) }
        return result
    }

    private func pointerDown(_ event: NSEvent, button: PointerButton) {
        window?.makeFirstResponder(self)
        let (screen, point) = screenPoint(event)
        // A pointer-down while busy finishes the previous gesture, which may have panned.
        let wasBusy = !interaction.isIdle
        let effects = interaction.pointerDown(at: point, hit: hitTarget(at: screen), button: button, modifiers: modifiers(event),
                                              clickCount: event.clickCount, context: interactionContext())
        if wasBusy { settlePan() }
        apply(effects)
    }

    private func pointerDragged(_ event: NSEvent) {
        apply(interaction.pointerDragged(to: screenPoint(event).1, modifiers: modifiers(event), context: interactionContext()))
    }

    private func pointerUp(_ event: NSEvent) {
        endGesture(interaction.pointerUp(at: screenPoint(event).1, context: interactionContext()))
    }

    private func endGesture(_ effects: [InteractionEffect]) {
        apply(effects)
        settlePan()
    }

    private func settlePan() {
        guard gesturePanned else { return }
        gesturePanned = false
        restingCursor.set()
        onViewportSettled?(viewport)
    }

    override func mouseDown(with event: NSEvent) { pointerDown(event, button: .primary) }
    override func mouseDragged(with event: NSEvent) { pointerDragged(event) }
    override func mouseUp(with event: NSEvent) { pointerUp(event) }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        pointerDown(event, button: .middle)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDragged(with: event); return }
        pointerDragged(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        pointerUp(event)
    }

    override func mouseMoved(with event: NSEvent) {
        let next: String?
        switch hitTarget(at: screenPoint(event).0) {
        case .frameHeader(let id), .frameContent(let id): next = id
        case .empty: next = nil
        }
        setHover(next)
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func setHover(_ id: String?) {
        guard hover != id else { return }
        hover = id
        refreshOverlay()
    }

    private func apply(_ effects: [InteractionEffect]) {
        for effect in effects {
            switch effect {
            case .select(let next):
                setSelection(next)
            case .moveFrames(let origins):
                setOrigins(origins)
            case .commitMove(let from, let to):
                setOrigins(to)
                onFramesMoved?(to)
                registerMove(from: from, to: to)
            case .marquee(let rect):
                marquee = rect
                refreshOverlay()
            case .guides(let next):
                guides = next
                refreshOverlay()
            case .pan(let next):
                if !gesturePanned { gesturePanned = true; NSCursor.closedHand.set() }
                viewport = next
                applyViewport()
                zoomIndicator?.update(viewport)
            case .focus(let id):
                onFocusFrame?(id)
            }
        }
    }

    private func setOrigins(_ origins: [String: Point]) {
        for (id, point) in origins {
            positions[id] = point
            frames[id]?.setFrameOrigin(NSPoint(x: point.x, y: point.y))
        }
        refreshOverlay()
    }

    // MARK: Undo

    /// Registers one undo step; undoing applies `from` and registers the reverse as the redo.
    private func registerMove(from: [String: Point], to: [String: Point]) {
        guard let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated {
                canvas.setOrigins(from)
                canvas.onFramesMoved?(from)
                canvas.registerMove(from: to, to: from)
            }
        }
        undoManager.setActionName("移动画框")
    }

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
        // dispatch. Canvas keys apply only when the canvas itself is first responder.
        guard window?.firstResponder === self else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let plain = flags.subtracting(.shift).isEmpty
        // Tool letters follow the typed character, not the physical key, so other layouts work.
        if flags.isEmpty || flags == .shift, let letter = event.charactersIgnoringModifiers?.lowercased(),
           letter == "v" || letter == "h" {
            onToolChange?(letter == "v" ? .move : .hand)
            return
        }
        switch event.keyCode {
        case 49: spaceHeld = true
        case 53:
            setSelection([])
        case 0 where flags == .command:
            setSelection(Set(frames.keys))
        case 18 where flags == .shift: onCommand?(.fitAll)
        case 19 where flags == .shift: onCommand?(.zoomToSelection)
        case 29 where flags == .shift: onCommand?(.actualSize)
        case 36 where plain:
            if selection.count == 1, let id = selection.first { frames[id]?.focusContent() }
        case 123, 124, 125, 126:
            guard plain, !selection.isEmpty, interaction.isIdle else { super.keyDown(with: event); return }
            nudgeSelection(keyCode: event.keyCode, step: flags.contains(.shift) ? 100 : 10)
        default:
            super.keyDown(with: event)
        }
    }

    /// One key press moves every selected frame and is one undo step.
    private func nudgeSelection(keyCode: UInt16, step: Double) {
        var from: [String: Point] = [:]
        var to: [String: Point] = [:]
        for id in selection {
            guard let origin = frames[id]?.frame.origin else { continue }
            var next = Point(x: origin.x, y: origin.y)
            switch keyCode {
            case 123: next.x -= step
            case 124: next.x += step
            case 125: next.y += step
            default: next.y -= step
            }
            from[id] = Point(x: origin.x, y: origin.y)
            to[id] = next
        }
        guard !to.isEmpty else { return }
        setOrigins(to)
        onFramesMoved?(to)
        registerMove(from: from, to: to)
    }

    // MARK: Scroll routing

    /// Maps an AppKit scroll event's phases to the router's vocabulary.
    static func scrollPhase(_ phase: NSEvent.Phase, momentum: NSEvent.Phase) -> ScrollPhase {
        if !momentum.isEmpty {
            return momentum.isDisjoint(with: [.ended, .cancelled]) ? .momentum : .momentumEnded
        }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        if phase.contains(.began) || phase.contains(.mayBegin) { return .began }
        if phase.isEmpty { return .discrete }
        return .changed
    }

    /// The routing decision for one scroll event; the per-gesture lock lives in `scrollRouter`.
    func routeScroll(phase: NSEvent.Phase, momentum: NSEvent.Phase, overActivePage: Bool, zoomModifier: Bool) -> ScrollTarget {
        scrollRouter.route(phase: Self.scrollPhase(phase, momentum: momentum), overActivePage: overActivePage, zoomModifier: zoomModifier)
    }

    /// Returns the event when AppKit should deliver it as usual, nil when it was handled here.
    func routeScrollEvent(_ event: NSEvent, at point: NSPoint) -> NSEvent? {
        let active = activeFrameID
        let over: Bool
        if case .frameContent(let id) = hitTarget(at: point), id == active { over = true } else { over = false }
        let zoom = !event.modifierFlags.isDisjoint(with: [.command, .control])
        switch routeScroll(phase: event.phase, momentum: event.momentumPhase, overActivePage: over, zoomModifier: zoom) {
        case .canvas:
            scrollWheel(with: event)
            return nil
        case .page:
            guard let page = active.flatMap({ frames[$0] })?.pageView else { return event }
            if let hit = hitTest(convert(point, to: superview), event: event), hit.isDescendant(of: page) { return event }
            page.scrollWheel(with: event)
            return nil
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        if tool == .hand { addCursorRect(bounds, cursor: .openHand) }
    }

    private var restingCursor: NSCursor { tool == .hand ? .openHand : .arrow }

    override func keyUp(with event: NSEvent) {
        if window?.firstResponder !== self { super.keyUp(with: event); return }
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }
}

private final class CanvasWorldView: NSView {
    override var isFlipped: Bool { true }
}
