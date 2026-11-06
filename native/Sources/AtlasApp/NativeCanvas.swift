import AppKit
import SwiftUI
@preconcurrency import WebKit
import AtlasCore

/// The document coordinate system scales; each web view keeps its CSS viewport size.
struct NativeCanvas: NSViewRepresentable {
    let project: Project
    let viewport: Viewport
    let positions: [String: Point]
    let interactingFrameID: String?
    let reloadToken: Int
    let onViewportChange: (Viewport) -> Void
    let onMoveFrame: (String, Point) -> Void
    let onInteractionChange: (String?) -> Void
    let onFocusFrame: (String) -> Void
    let onSizeChange: (CGSize) -> Void

    func makeNSView(context: Context) -> AtlasCanvasView {
        let view = AtlasCanvasView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AtlasCanvasView, context: Context) {
        view.onViewportChange = onViewportChange
        view.onMoveFrame = onMoveFrame
        view.onInteractionChange = onInteractionChange
        view.onFocusFrame = onFocusFrame
        view.onSizeChange = onSizeChange
        view.update(project: project, viewport: viewport, positions: positions,
                    interactingFrameID: interactingFrameID, reloadToken: reloadToken)
    }

    static func dismantleNSView(_ view: AtlasCanvasView, coordinator: ()) {
        view.dispose()
    }
}

final class AtlasCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onViewportChange: ((Viewport) -> Void)?
    var onMoveFrame: ((String, Point) -> Void)?
    var onInteractionChange: ((String?) -> Void)?
    var onFocusFrame: ((String) -> Void)?
    var onSizeChange: ((CGSize) -> Void)?
    private let world = CanvasWorldView()
    private var frames: [String: PreviewFrameView] = [:]
    private var projectID: String?
    private var reloadToken: Int?
    private var viewport = Viewport()
    private var positions: [String: Point] = [:]
    private var selectedFrameID: String?
    private var interactingFrameID: String?
    private var panStart: (CGPoint, Viewport)?
    private var eventMonitor: Any?
    fileprivate var spaceHeld = false
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
        guard window != nil else { return }
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
        frames.values.forEach { $0.dispose() }
        frames.removeAll()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func update(project: Project, viewport: Viewport, positions: [String: Point],
                interactingFrameID: String?, reloadToken: Int) {
        self.viewport = viewport
        self.positions = positions
        let leavingInteraction = self.interactingFrameID != nil && interactingFrameID == nil
        self.interactingFrameID = interactingFrameID
        if projectID != project.id {
            frames.values.forEach { $0.dispose(); $0.removeFromSuperview() }
            frames.removeAll()
            selectedFrameID = nil
            projectID = project.id
            for frame in project.frames {
                let view = PreviewFrameView(frame: frame, baseURL: project.preview.baseUrl)
                view.canvas = self
                frames[frame.id] = view
                world.addSubview(view)
            }
            self.reloadToken = reloadToken
        }
        if self.reloadToken != reloadToken {
            frames.values.forEach { $0.reload() }
            self.reloadToken = reloadToken
        }
        for frame in project.frames {
            guard let view = frames[frame.id] else { continue }
            let position = positions[frame.id] ?? Point(x: frame.x, y: frame.y)
            view.frame = NSRect(x: position.x, y: position.y, width: frame.width,
                                height: frame.height + CanvasGeometry.headerHeight)
            view.interactive = interactingFrameID == frame.id
            view.selected = selectedFrameID == frame.id
        }
        if leavingInteraction { window?.makeFirstResponder(self) }
        applyViewport()
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

    fileprivate func select(_ id: String) {
        if let interactingFrameID, interactingFrameID != id { onInteractionChange?(nil) }
        selectedFrameID = id
        for (frameID, frame) in frames { frame.selected = frameID == id }
        if interactingFrameID == id { frames[id]?.focusContent() }
        else { window?.makeFirstResponder(self) }
    }

    fileprivate func interact(_ id: String) {
        select(id)
        onInteractionChange?(id)
    }

    fileprivate func focus(_ id: String) { select(id); onFocusFrame?(id) }

    fileprivate func move(_ id: String, delta: CGPoint, from start: Point) {
        let point = CanvasGeometry.moveFrame(start, screenDelta: Point(x: delta.x, y: delta.y), scale: viewport.scale)
        positions[id] = point
        if let frame = frames[id] { frame.setFrameOrigin(NSPoint(x: point.x, y: point.y)) }
        onMoveFrame?(id, point)
    }

    fileprivate func position(of id: String) -> Point { positions[id] ?? Point(x: 0, y: 0) }

    fileprivate func beginPan(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        panStart = (convert(event.locationInWindow, from: nil), viewport)
        NSCursor.closedHand.set()
    }

    fileprivate func continuePan(_ event: NSEvent) {
        guard let (start, initial) = panStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        viewport = Viewport(x: initial.x + point.x - start.x, y: initial.y + point.y - start.y, scale: initial.scale)
        applyViewport()
        onViewportChange?(viewport)
    }

    fileprivate func endPan() { panStart = nil; NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) { beginPan(event) }
    override func mouseDragged(with event: NSEvent) { continuePan(event) }
    override func mouseUp(with event: NSEvent) { endPan() }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let point = convert(event.locationInWindow, from: nil)
            viewport = CanvasGeometry.zoomAt(viewport, point: Point(x: point.x, y: point.y),
                                             scale: viewport.scale * exp(-event.scrollingDeltaY * 0.01))
        } else {
            viewport = Viewport(x: viewport.x + event.scrollingDeltaX, y: viewport.y + event.scrollingDeltaY, scale: viewport.scale)
        }
        applyViewport()
        onViewportChange?(viewport)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        viewport = CanvasGeometry.zoomAt(viewport, point: Point(x: point.x, y: point.y), scale: viewport.scale * (1 + event.magnification))
        applyViewport()
        onViewportChange?(viewport)
    }

    override func keyDown(with event: NSEvent) {
        // WebKit may pass an unhandled key up the native responder chain after DOM
        // dispatch. The page bridge alone decides whether Escape exits interaction.
        if interactingFrameID != nil { return }
        if event.keyCode == 49 { spaceHeld = true; return }
        if event.keyCode == 53 { return }
        guard let id = selectedFrameID, let position = positions[id] else { super.keyDown(with: event); return }
        let step: Double = event.modifierFlags.contains(.shift) ? 100 : 10
        var next = position
        switch event.keyCode {
        case 123: next.x -= step
        case 124: next.x += step
        case 125: next.y += step
        case 126: next.y -= step
        case 36: onInteractionChange?(id); return
        default: super.keyDown(with: event); return
        }
        positions[id] = next
        frames[id]?.setFrameOrigin(NSPoint(x: next.x, y: next.y))
        onMoveFrame?(id, next)
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

private final class PreviewFrameView: NSView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    override var isFlipped: Bool { true }
    weak var canvas: AtlasCanvasView?
    private let definition: Frame
    private let previewURL: URL?
    private let webView: WKWebView
    private let interactionButton = NSButton()
    private let externalButton = NSButton()
    private let retryButton = NSButton()
    private let status = NSTextField(labelWithString: "正在加载预览…")
    private let progress = NSProgressIndicator()
    private var timeout: DispatchWorkItem?
    private var dragStart: (CGPoint, Point)?
    private var panning = false
    private var hasDisposed = false
    var interactive = false {
        didSet {
            interactionButton.title = interactive ? "退出交互" : "进入交互"
            interactionButton.image = NSImage(systemSymbolName: interactive ? "hand.raised" : "cursorarrow.and.square.on.square.dashed", accessibilityDescription: nil)
            needsDisplay = true
            if interactive && !oldValue { focusContent() }
        }
    }
    var selected = false { didSet { needsDisplay = true } }

    init(frame: Frame, baseURL: String) {
        definition = frame
        previewURL = try? frame.previewURL(baseURL: baseURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(source: Self.escapeScript,
                                                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: CanvasGeometry.headerHeight, width: frame.width, height: frame.height), configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.add(self, name: "atlasExit")
        addSubview(webView)
        interactionButton.bezelStyle = .inline
        interactionButton.controlSize = .small
        interactionButton.font = .systemFont(ofSize: 11)
        interactionButton.title = "进入交互"
        interactionButton.target = self
        interactionButton.action = #selector(toggleInteraction)
        interactionButton.setAccessibilityLabel("\(frame.title)，进入或退出交互")
        addSubview(interactionButton)
        externalButton.bezelStyle = .inline
        externalButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "在浏览器打开")
        externalButton.imagePosition = .imageOnly
        externalButton.target = self
        externalButton.action = #selector(openExternal)
        externalButton.toolTip = "在浏览器打开这个画框"
        externalButton.setAccessibilityLabel("在浏览器打开\(frame.title)")
        externalButton.isEnabled = previewURL != nil
        addSubview(externalButton)
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 14)
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        addSubview(status)
        progress.style = .spinning
        progress.controlSize = .regular
        progress.isDisplayedWhenStopped = false
        addSubview(progress)
        retryButton.title = "重新加载"
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isHidden = true
        addSubview(retryButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(frame.title)，\(Self.dimensions(frame))，画框")
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func dispose() {
        hasDisposed = true
        timeout?.cancel()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "atlasExit")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    override func layout() {
        super.layout()
        // Content bounds remain in CSS pixels even when the ancestor is magnified.
        webView.frame = NSRect(x: 0, y: CanvasGeometry.headerHeight, width: definition.width, height: definition.height)
        interactionButton.frame = NSRect(x: max(0, bounds.width - 134), y: 12, width: 90, height: 22)
        externalButton.frame = NSRect(x: max(0, bounds.width - 36), y: 12, width: 24, height: 22)
        status.frame = NSRect(x: 24, y: CanvasGeometry.headerHeight + min(200, definition.height * 0.38), width: max(1, bounds.width - 48), height: 58)
        progress.frame = NSRect(x: bounds.midX - 12, y: status.frame.minY - 38, width: 24, height: 24)
        retryButton.frame = NSRect(x: bounds.midX - 52, y: status.frame.maxY + 12, width: 104, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: CanvasGeometry.headerHeight).fill()
        let title = definition.title as NSString
        title.draw(in: NSRect(x: 14, y: 8, width: max(1, bounds.width - 155), height: 17),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let platform = ["mobile": "移动端", "web": "网页端", "desktop": "桌面端"][definition.platform] ?? definition.platform
        let detail = "\(platform) · \(Self.dimensions(definition))" as NSString
        detail.draw(in: NSRect(x: 14, y: 26, width: max(1, bounds.width - 155), height: 14),
                    withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.7, dy: 0.7), xRadius: 10, yRadius: 10)
        (interactive || selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        border.lineWidth = interactive || selected ? 2 : 1
        border.stroke()
    }

    private static func dimensions(_ frame: Frame) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(.never)
        return "\(frame.width.formatted(format)) × \(frame.height.formatted(format))"
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        guard result != nil else { return nil }
        let local = convert(point, from: superview)
        if interactionButton.frame.contains(local) { return interactionButton }
        if externalButton.frame.contains(local) { return externalButton }
        if !retryButton.isHidden, retryButton.frame.contains(local) { return retryButton }
        if local.y < CanvasGeometry.headerHeight || !interactive || canvas?.spaceHeld == true { return self }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        let local = convert(event.locationInWindow, from: nil)
        panning = canvas.spaceHeld
        if panning { canvas.beginPan(event); return }
        canvas.select(definition.id)
        if local.y < CanvasGeometry.headerHeight {
            if event.clickCount == 2 { canvas.focus(definition.id); return }
            dragStart = (canvas.convert(event.locationInWindow, from: nil), canvas.position(of: definition.id))
            NSCursor.closedHand.set()
        } else if event.clickCount == 2 {
            canvas.interact(definition.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas else { return }
        if panning { canvas.continuePan(event); return }
        guard let (start, position) = dragStart else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        canvas.move(definition.id, delta: CGPoint(x: point.x - start.x, y: point.y - start.y), from: position)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if panning { canvas?.endPan(); panning = false }
        NSCursor.arrow.set()
    }

    override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { canvas?.magnify(with: event) }

    @objc private func toggleInteraction() {
        if interactive { canvas?.onInteractionChange?(nil) } else { canvas?.interact(definition.id) }
    }

    @objc private func retry() { reload() }

    fileprivate func focusContent() {
        if !webView.isHidden { window?.makeFirstResponder(webView) }
    }

    @objc private func openExternal() {
        guard let previewURL else { return }
        let current = webView.url.flatMap { isPreviewOrigin($0) ? $0 : nil } ?? previewURL
        NSWorkspace.shared.open(current)
    }

    func reload() {
        timeout?.cancel()
        guard let previewURL else { showFailure("预览地址无效，请检查 catalog.json。"); return }
        status.stringValue = "正在加载预览…"
        status.isHidden = false
        retryButton.isHidden = true
        progress.startAnimation(nil)
        webView.isHidden = true
        webView.load(URLRequest(url: previewURL, timeoutInterval: 30))
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasDisposed else { return }
            self.webView.stopLoading()
            self.showFailure("预览加载超时。请确认案例服务正常运行。")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: work)
    }

    private func showFailure(_ message: String) {
        timeout?.cancel()
        status.stringValue = message
        status.isHidden = false
        retryButton.isHidden = false
        progress.stopAnimation(nil)
        webView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.cancel()
        status.isHidden = true
        retryButton.isHidden = true
        progress.stopAnimation(nil)
        webView.isHidden = false
        if interactive { focusContent() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showFailure("预览加载失败：\(error.localizedDescription)") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showFailure("预览加载失败：\(error.localizedDescription)") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showFailure("预览进程已结束，可以重新加载。") }

    private func isPreviewOrigin(_ url: URL) -> Bool {
        guard let previewURL else { return false }
        return url.scheme == previewURL.scheme && url.host == previewURL.host && (url.port ?? 80) == (previewURL.port ?? 80)
            && url.user == nil && url.password == nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if isPreviewOrigin(url) { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            showFailure("预览返回 HTTP \(response.statusCode)，请检查案例路径。")
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "atlasExit", message.frameInfo.isMainFrame, interactive,
              let url = message.frameInfo.request.url, isPreviewOrigin(url) else { return }
        canvas?.onInteractionChange?(nil)
    }

    private static let escapeScript = """
    (() => {
      const dialogsAtKeydown = new WeakMap();
      window.addEventListener('keydown', event => {
        if (event.key === 'Escape') dialogsAtKeydown.set(event, !!document.querySelector('dialog[open]'));
      }, true);
      window.addEventListener('keydown', event => {
        if (event.key !== 'Escape') return;
        const dialogWasOpen = dialogsAtKeydown.get(event);
        setTimeout(() => {
          if (!event.defaultPrevented && !dialogWasOpen && !document.querySelector('dialog[open]')) {
            window.webkit.messageHandlers.atlasExit.postMessage('exit');
          }
        }, 0);
      });
    })();
    """
}
