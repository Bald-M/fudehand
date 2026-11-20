import AppKit
import FudehandCore

/// The edits and state the canvas reports to the owner of the document (`FudehandStore`); the canvas itself does not modify the document.
@MainActor
protocol CanvasHost: AnyObject {
    func canvasSelect(_ ids: Set<String>)
    func canvasBeginGesture(_ name: String)
    /// The new top-left corners of the layers being dragged (absolute canvas coordinates).
    func canvasMove(_ origins: [String: Point])
    /// The new rectangle of the layer being resized (absolute canvas coordinates).
    func canvasResize(_ id: String, to rect: Rect)
    func canvasEndGesture()
    func canvasCreate(_ type: NodeType, in rect: Rect, clicked: Bool)
    func canvasNudge(_ ids: Set<String>, by delta: Point)
    func canvasDelete(_ ids: Set<String>)
    func canvasToolChanged(_ tool: CanvasTool)
    func canvasCommand(_ command: CanvasCommand)
    func canvasFocus(_ id: String)
    func canvasViewportSettled(_ viewport: Viewport)
    func canvasSizeChanged(_ size: CGSize)
    /// The layer under the pointer changed (nil when none).
    func canvasHover(_ id: String?)
}

final class FudehandCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    weak var host: CanvasHost?
    var zoomIndicator: ZoomIndicator?
    /// Holds `world`; a pending zoom is shown as its layer's sublayer transform.
    let zoomHost = CanvasFlippedView()
    let world = CanvasFlippedView()
    let gridLayer = CanvasGrid()
    let overlay = CanvasOverlay()
    let renderer = DesignRenderer()
    /// The document on screen with its lookup index; the store builds it once per document change.
    private(set) var index = DesignIndex()
    var document: DesignDocument { index.document }
    private(set) var selection: Set<String> = []
    private var requestToken: Int?
    /// Where the toolbar floating above the canvas sits, in canvas coordinates. SwiftUI still routes the pointer events it
    /// does not handle there to the canvas underneath, so the canvas ignores them itself.
    var floatingFrame = CGRect.zero {
        didSet { if floatingFrame != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    private func isOverFloatingView(_ event: NSEvent) -> Bool { floatingFrame.contains(convert(event.locationInWindow, from: nil)) }
    private(set) var tool = CanvasTool.move {
        didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    /// What is on screen right now; overlay, hit testing and interaction use it.
    var liveViewport = Viewport()
    /// What `world.bounds` reflects; differs from `liveViewport` only while a zoom is pending.
    var committedViewport = Viewport()
    var animation: ViewportAnimationRun?
    /// Whether viewport changes skip their animation; follows the system "Reduce motion" setting (#174).
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The layers listed for VoiceOver, kept by id so an element stays the same object while it is focused.
    private var accessibilityElements: [String: CanvasLayerElement] = [:]
    var lastIndicatorUpdate: CFTimeInterval = 0
    private var interaction = CanvasInteraction()
    private(set) var hover: String?
    private var marquee: Rect?
    private var guides: [Guide] = []
    /// Set when the current gesture panned, so its end reports the settled viewport.
    private var gesturePanned = false
    var settleWork: DispatchWorkItem?
    private var eventMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    /// Holding Space shows the hand right away, before any drag starts.
    var spaceHeld = false {
        didSet {
            guard spaceHeld != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if !gesturePanned { restingCursor.set() }
        }
    }
    private var lastReportedSize = CGSize.zero
    var activeDisplayLink: CADisplayLink?
    var frameLog = FrameIntervalLog()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.insertSublayer(gridLayer, at: 0)
        zoomHost.wantsLayer = true
        world.wantsLayer = true
        zoomHost.addSubview(world)
        world.layer?.addSublayer(renderer.root)
        addSubview(zoomHost)
        addSubview(overlay)
        updateColors()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // Read on demand so they follow the UI language.
    override func accessibilityLabel() -> String? { L("Design canvas") }
    override func accessibilityHelp() -> String? {
        L("Click to select a layer, drag to move it, and drag a handle to resize it; drag empty space to select with a marquee; scroll or hold Space and drag to pan; hold Command and scroll to zoom.")
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }
    override func accessibilityChildren() -> [Any]? { accessibilityLayers() }
    override func accessibilitySelectedChildren() -> [Any]? { accessibilityLayers().filter { $0.isAccessibilitySelected() } }

    /// Pointing at a layer (VoiceOver cursor tracking, Accessibility Inspector) finds its element: the layer itself when
    /// it is listed, otherwise its top-level layer.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard case .node(let id) = hitTarget(at: local) else { return self }
        let layers = accessibilityLayers()
        let listed = index.ancestry(of: id).reversed().lazy.compactMap { ancestor in layers.first { $0.id == ancestor } }.first
        return listed ?? self
    }

    /// The top-level layers and the selection as VoiceOver elements, positioned for the live viewport.
    func accessibilityLayers() -> [CanvasLayerElement] {
        let items = CanvasAccessibility.items(index: index, selection: selection)
        var next: [String: CanvasLayerElement] = [:]
        let elements = items.map { item -> CanvasLayerElement in
            let element = accessibilityElements[item.id] ?? CanvasLayerElement(id: item.id, canvas: self)
            element.setAccessibilityLabel(item.name)
            element.setAccessibilityRoleDescription(item.type.title)
            element.setAccessibilitySelected(item.selected)
            let r = item.viewRect(liveViewport)
            element.setAccessibilityFrameInParentSpace(NSRect(x: r.x, y: r.y, width: r.width, height: r.height))
            next[item.id] = element
            return element
        }
        accessibilityElements = next
        return elements
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        removeFocusObservers()
        updateDisplayLink()
        updateContentsScale()
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .keyUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyUp, event.keyCode == 49 { self.spaceHeld = false; return event }
            guard event.type == .magnify, self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  !self.isOverFloatingView(event) else { return event }
            self.magnify(with: event)
            return nil
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    func dispose() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        removeFocusObservers()
        settleWork?.cancel()
        animation = nil
        stopDisplayLink()
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
    /// key-up or mouse-up will not arrive here. An in-progress move or resize keeps its result.
    func releaseHeldInput() {
        spaceHeld = false
        endGesture(interaction.cancel())
        if animation == nil { commitPendingZoom() }
    }

    // MARK: Updates from the store

    /// Shows the document; called on every document change, including during drags.
    func show(_ next: DesignIndex) {
        index = next
        renderer.sync(next.document.nodes)
        if !selection.allSatisfy(next.contains) {
            selection = selection.filter(next.contains)
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
        if let hover, !next.contains(hover) { self.hover = nil; host?.canvasHover(nil) }
        refreshOverlay()
    }

    /// The available fonts changed; the store follows with `show`.
    func fontsChanged() { renderer.fontsChanged() }

    func setSelection(_ next: Set<String>) {
        guard next != selection else { return }
        selection = next
        refreshOverlay()
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    func update(viewportRequest: ViewportRequest, tool: CanvasTool) {
        self.tool = tool
        if requestToken != viewportRequest.token {
            requestToken = viewportRequest.token
            apply(viewportRequest)
        }
    }

    /// Text and images are rasterized for the committed zoom so they stay sharp. The zoom is rounded up to a
    /// power of two, so zooming within one step reuses the existing bitmaps instead of redrawing every text layer.
    func updateContentsScale() {
        let backing = window?.backingScaleFactor ?? 2
        renderer.contentsScale = backing * CGFloat(Self.rasterZoom(committedViewport.scale))
    }

    static func rasterZoom(_ scale: Double) -> Double {
        let clamped = min(max(scale, 0.25), CanvasGeometry.maxScale)
        return pow(2, (log2(clamped) - 1e-9).rounded(.up))
    }

    func refreshOverlay() {
        overlay.render(viewport: liveViewport, index: index, selection: selection, hover: hover,
                       marquee: marquee, guides: guides, handlesFor: handleTarget)
    }

    override func layout() {
        super.layout()
        applyViewport()
        if bounds.size != lastReportedSize, bounds.width > 0, bounds.height > 0 {
            lastReportedSize = bounds.size
            let size = bounds.size
            DispatchQueue.main.async { [weak self] in self?.host?.canvasSizeChanged(size) }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        gridLayer.updateColor(for: effectiveAppearance)
    }

    // MARK: Hit testing

    /// The single selected layer that shows resize handles; groups resize with their children and have none.
    var handleTarget: String? {
        guard selection.count == 1, let id = selection.first, let node = index.node(id), node.type != .group, !node.locked else { return nil }
        return id
    }

    func worldPoint(_ screen: NSPoint) -> Point {
        CanvasGeometry.screenToWorld(Point(x: screen.x, y: screen.y), viewport: liveViewport)
    }

    /// What a press at a canvas (screen-space) point targets: a handle, a top-level frame label, or a layer.
    func hitTarget(at screen: NSPoint, deep: Bool = false) -> HitTarget {
        if let id = handleTarget, let rect = index.worldRect(id) {
            for handle in ResizeHandle.allCases {
                let anchor = CanvasOverlay.screenPoint(handle, of: rect, viewport: liveViewport)
                if abs(anchor.x - screen.x) <= CanvasOverlay.handleHitRadius, abs(anchor.y - screen.y) <= CanvasOverlay.handleHitRadius {
                    return .handle(id, handle)
                }
            }
        }
        for node in document.nodes.reversed() where node.type == .frame && node.visible && !node.locked {
            if CanvasOverlay.labelRect(for: node, viewport: liveViewport).contains(screen) { return .label(node.id) }
        }
        let path = DesignHitTest.path(at: worldPoint(screen), in: document)
        return DesignHitTest.selectable(path: path, selection: selection, index: index, deep: deep).map(HitTarget.node) ?? .empty
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func interactionContext() -> InteractionContext {
        var rects: [String: Rect] = [:]
        for node in document.nodes { rects[node.id] = node.frame }
        var movable = Set<String>()
        var snapTargets: [Rect] = []
        var parents = Set<String?>()
        for id in selection {
            guard let rect = index.worldRect(id), let node = index.node(id), let parent = index.parentID(of: id) else { continue }
            rects[id] = rect
            parents.insert(parent)
            let parentHasLayout = parent.flatMap { index.node($0)?.layout } != nil
            if !node.locked, !parentHasLayout { movable.insert(id) }
        }
        for parent in parents {
            let siblings = parent.flatMap { index.node($0)?.children } ?? document.nodes
            for sibling in siblings where !selection.contains(sibling.id) && sibling.visible {
                if let rect = index.worldRect(sibling.id) { snapTargets.append(rect) }
            }
            if let parent, let rect = index.worldRect(parent) {
                snapTargets.append(rect)
                if let frame = index.guideFrames.first(where: { $0.id == parent }) {
                    snapTargets += frame.guides.flatMap { $0.snapRects(in: frame.rect) }
                }
            }
        }
        let candidates = Set(document.nodes.filter { $0.visible && !$0.locked }.map(\.id))
        return InteractionContext(viewport: liveViewport, rects: rects, marqueeCandidates: candidates, snapTargets: snapTargets,
                                  movable: movable, selection: selection, tool: tool, spaceHeld: spaceHeld)
    }

    // MARK: Pointer input

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
        guard !isOverFloatingView(event) else { return }
        commitPendingZoom()
        window?.makeFirstResponder(self)
        let (screen, point) = screenPoint(event)
        let wasBusy = !interaction.isIdle
        let hit = hitTarget(at: screen, deep: event.modifierFlags.contains(.command))
        let effects = interaction.pointerDown(at: point, hit: hit, button: button, modifiers: modifiers(event),
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
        settleViewport()
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
        if isOverFloatingView(event) { setHover(nil); return }
        if spaceHeld, !gesturePanned { NSCursor.openHand.set() }
        let next: String?
        switch hitTarget(at: screenPoint(event).0, deep: event.modifierFlags.contains(.command)) {
        case .node(let id), .label(let id): next = id
        case .handle, .empty: next = nil
        }
        setHover(next)
    }

    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func setHover(_ id: String?) {
        guard hover != id else { return }
        showHover(id)
        host?.canvasHover(id)
    }

    /// Outlines the layer hovered in the layers panel.
    func showHover(_ id: String?) {
        guard hover != id else { return }
        hover = id
        refreshOverlay()
    }

    private func apply(_ effects: [InteractionEffect]) {
        for effect in effects {
            switch effect {
            case .select(let next):
                report(next)
            case .beginGesture(let name):
                host?.canvasBeginGesture(name)
            case .moveNodes(let origins):
                host?.canvasMove(origins)
            case .resize(let id, let rect):
                host?.canvasResize(id, to: rect)
            case .endGesture:
                host?.canvasEndGesture()
            case .marquee(let rect):
                marquee = rect
                refreshOverlay()
            case .guides(let next):
                guides = next
                refreshOverlay()
            case .pan(let next):
                if !gesturePanned { gesturePanned = true; NSCursor.closedHand.set() }
                setLiveViewport(next, zooming: false)
            case .focus(let id):
                host?.canvasFocus(id)
            case .enter(let id, let point):
                if let child = DesignHitTest.enter(id, at: point, in: document) { report([child]) }
            case .create(let type, let rect, let clicked):
                host?.canvasCreate(type, in: rect, clicked: clicked)
            }
        }
    }

    // MARK: Scroll and zoom

    override func scrollWheel(with event: NSEvent) {
        guard !isOverFloatingView(event) else { return }
        stopAnimation()
        // A line-based mouse wheel reports about one unit per notch; trackpads report points.
        let delta = CanvasGeometry.wheelDelta(Point(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
                                              precise: event.hasPreciseScrollingDeltas)
        let viewport = liveViewport
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let point = convert(event.locationInWindow, from: nil)
            let scale = CanvasGeometry.wheelZoomScale(viewport.scale, deltaY: delta.y)
            setLiveViewport(CanvasGeometry.zoomAt(viewport, point: Point(x: point.x, y: point.y), scale: scale), zooming: true)
        } else {
            setLiveViewport(Viewport(x: viewport.x + delta.x, y: viewport.y + delta.y, scale: viewport.scale), zooming: false)
        }
        settleSoon()
    }

    override func magnify(with event: NSEvent) {
        magnify(by: event.magnification, at: convert(event.locationInWindow, from: nil), phase: event.phase)
    }

    /// A pinch zooms as a transform until it ends, or until 150ms pass without another magnify event.
    func magnify(by magnification: Double, at point: NSPoint, phase: NSEvent.Phase) {
        stopAnimation()
        let viewport = liveViewport
        setLiveViewport(CanvasGeometry.zoomAt(viewport, point: Point(x: point.x, y: point.y), scale: viewport.scale * (1 + magnification)),
                        zooming: true)
        if !phase.isDisjoint(with: [.ended, .cancelled]) {
            settleWork?.cancel()
            settleViewport()
        } else {
            settleSoon()
        }
    }

    // MARK: Keyboard

    static let toolKeys: [String: CanvasTool] = ["v": .move, "h": .hand, "f": .frame, "r": .rectangle, "o": .ellipse, "t": .text]

    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let plain = flags.subtracting(.shift).isEmpty
        let action: () -> Void
        // Tool letters follow the typed character, not the physical key, so other layouts work.
        if flags.isEmpty, let letter = event.charactersIgnoringModifiers?.lowercased(), let next = Self.toolKeys[letter] {
            action = { self.host?.canvasToolChanged(next) }
        } else {
            switch event.keyCode {
            case 49: action = { self.spaceHeld = true }
            case 53: action = { self.selectParent() }
            case 36 where flags.isEmpty: action = { self.selectChildren() }
            case 51, 117:
                guard flags.isEmpty, !selection.isEmpty, interaction.isIdle else { super.keyDown(with: event); return }
                action = { self.host?.canvasDelete(self.selection) }
            case 0 where flags == .command: action = { self.selectAllSiblings() }
            case 18 where flags == .shift: action = { self.host?.canvasCommand(.fitAll) }
            case 19 where flags == .shift: action = { self.host?.canvasCommand(.zoomToSelection) }
            case 29 where flags == .shift: action = { self.host?.canvasCommand(.actualSize) }
            case 123, 124, 125, 126:
                guard plain, !selection.isEmpty, interaction.isIdle else { super.keyDown(with: event); return }
                let step = flags.contains(.shift) ? 10.0 : 1.0
                let delta: Point
                switch event.keyCode {
                case 123: delta = Point(x: -step, y: 0)
                case 124: delta = Point(x: step, y: 0)
                case 125: delta = Point(x: 0, y: step)
                default: delta = Point(x: 0, y: -step)
                }
                action = { self.host?.canvasNudge(self.selection, by: delta) }
            default:
                super.keyDown(with: event)
                return
            }
        }
        commitPendingZoom()
        action()
    }

    private func report(_ next: Set<String>) {
        selection = next
        host?.canvasSelect(next)
        refreshOverlay()
    }

    /// VoiceOver pressed a layer element: select it as a click would.
    func selectFromAccessibility(_ id: String) {
        guard index.contains(id) else { return }
        commitPendingZoom()
        report([id])
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    /// Esc selects the parent layer, or clears the selection at the top level.
    private func selectParent() {
        report(Set(selection.compactMap { document.parentID(of: $0) ?? nil }))
    }

    /// Return selects the children of the selected containers.
    private func selectChildren() {
        let children = selection.flatMap { id in (document.node(id)?.children ?? []).filter(\.visible).map(\.id) }
        if !children.isEmpty { report(Set(children)) }
    }

    /// ⌘A selects every layer at the level of the current selection (the top level when nothing is selected).
    private func selectAllSiblings() {
        let parent = selection.first.flatMap { document.parentID(of: $0) ?? nil }
        let siblings = parent.flatMap { document.node($0)?.children } ?? document.nodes
        report(Set(siblings.filter { $0.visible && !$0.locked }.map(\.id)))
    }

    // MARK: Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        if tool == .hand || spaceHeld { cursor = .openHand } else if tool.creates != nil { cursor = .crosshair } else { return }
        // The four strips around the floating toolbar, so the pointer stays an arrow over it.
        let (b, f) = (bounds, floatingFrame)
        for rect in [CGRect(x: b.minX, y: b.minY, width: b.width, height: f.minY - b.minY),
                     CGRect(x: b.minX, y: f.maxY, width: b.width, height: b.maxY - f.maxY),
                     CGRect(x: b.minX, y: f.minY, width: f.minX - b.minX, height: f.height),
                     CGRect(x: f.maxX, y: f.minY, width: b.maxX - f.maxX, height: f.height)] where rect.width > 0 && rect.height > 0 {
            addCursorRect(rect, cursor: cursor)
        }
    }

    private var restingCursor: NSCursor { tool == .hand || spaceHeld ? .openHand : tool.creates != nil ? .crosshair : .arrow }

    override func keyUp(with event: NSEvent) {
        if window?.firstResponder !== self { super.keyUp(with: event); return }
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }
}

final class CanvasFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A layer on the canvas as VoiceOver sees it; pressing it selects the layer.
final class CanvasLayerElement: NSAccessibilityElement {
    let id: String
    private weak var canvas: FudehandCanvasView?

    init(id: String, canvas: FudehandCanvasView) {
        self.id = id
        self.canvas = canvas
        super.init()
        setAccessibilityParent(canvas)
        setAccessibilityRole(.layoutItem)
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let canvas else { return false }
            canvas.selectFromAccessibility(id)
            return true
        }
    }
}
