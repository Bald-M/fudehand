import AppKit
@preconcurrency import WebKit
import AtlasCore

final class PreviewFrameView: NSView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    override var isFlipped: Bool { true }
    weak var canvas: AtlasCanvasView?
    private let definition: Frame
    private let previewURL: URL?
    private let webView: WKWebView
    private let externalButton = NSButton()
    private let retryButton = NSButton()
    private let status = NSTextField(labelWithString: "正在加载预览…")
    private let progress = NSProgressIndicator()
    private var timeout: DispatchWorkItem?
    private var hasDisposed = false
    /// Set when a response is rejected, so the follow-up cancellation error keeps the HTTP message.
    private var rejectedResponse = false
    var frameID: String { definition.id }
    /// 网页最近的控制台输出与未捕获错误；网页重载后仍保留。
    private(set) var console = FrameConsole()
    /// 读取和交互脚本在独立的脚本世界执行，页面自己的脚本改不到它们。
    private static let agentWorld = WKContentWorld.world(name: "界面图鉴")
    /// True once the page has loaded; only a ready frame can become the active frame that receives web input.
    /// Set only by navigation callbacks; settable internally so tests can simulate a loaded page.
    var isReady = false {
        didSet { if isReady != oldValue { canvas?.frameReadinessChanged(self) } }
    }

    init(frame: Frame, baseURL: String) {
        definition = frame
        previewURL = try? frame.previewURL(baseURL: baseURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(source: Self.escapeScript,
                                                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.hideScrollbarsScript,
                                                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: FramePageScripts.console,
                                                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: CanvasGeometry.headerHeight, width: frame.width, height: frame.height), configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
        // In a full-size-content window WebKit treats the part of a frame panned under the toolbar as obscured and
        // pushes the page down, shrinking its viewport. Frames always show their whole CSS viewport (#14).
        let setAutomaticInsets = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if webView.responds(to: setAutomaticInsets) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: setAutomaticInsets), to: Setter.self)(webView, setAutomaticInsets, false)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.add(self, name: "atlasExit")
        webView.configuration.userContentController.add(self, name: "atlasConsole")
        addSubview(webView)
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
        updateAccessibility(selected: false, active: false)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func dispose() {
        hasDisposed = true
        timeout?.cancel()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "atlasExit")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "atlasConsole")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    override func layout() {
        super.layout()
        // Content bounds remain in CSS pixels even when the ancestor is magnified.
        webView.frame = NSRect(x: 0, y: CanvasGeometry.headerHeight, width: definition.width, height: definition.height)
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
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.separatorColor.setStroke()
        border.lineWidth = 1
        border.stroke()
    }

    func updateAccessibility(selected: Bool, active: Bool) {
        let state = active ? "，活动" : selected ? "，已选中" : ""
        setAccessibilityLabel("\(definition.title)，\(Self.dimensions(definition))，画框\(state)")
    }

    private static func dimensions(_ frame: Frame) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(.never)
        return "\(frame.width.formatted(format)) × \(frame.height.formatted(format))"
    }

    /// The frame's own control under `point` (frame coordinates); these stay clickable in every state.
    func control(at point: NSPoint) -> NSView? {
        if externalButton.frame.contains(point) { return externalButton }
        if !retryButton.isHidden, retryButton.frame.contains(point) { return retryButton }
        return nil
    }

    @objc private func retry() { reload() }

    /// The web view, for routing scroll events to the page.
    var pageView: NSView { webView }

    func focusContent() {
        if isReady { window?.makeFirstResponder(webView) }
    }

    /// 以 CSS 视口宽度截取网页，返回 PNG（像素按屏幕倍率）。网页进程无响应时 10 秒后失败。
    func snapshotPNG() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: definition.width)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<NSImage, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            webView.takeSnapshot(with: configuration) { image, error in
                finish(image.map { .success($0) } ?? .failure(error ?? ControlCommandError("截图失败")))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(.failure(ControlCommandError("截图超时"))) }
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw ControlCommandError("截图无法编码为 PNG")
        }
        return png
    }

    /// 读取网页的精简文本大纲：标题、文本和可交互元素（附 CSS 选择器），最多约 20000 字。
    func readPage() async throws -> [String: Any] {
        try await runAgentScript(FramePageScripts.read, arguments: [:])
    }

    /// 在网页中按选择器点击、填值或滚动。只操作当前预览页面，不导航到其他站点。
    func interact(_ action: FrameAction) async throws -> [String: Any] {
        var arguments: [String: Any] = ["selector": NSNull(), "value": NSNull(), "deltaX": 0, "deltaY": 0]
        switch action {
        case .click(let selector):
            arguments["action"] = "click"; arguments["selector"] = selector
        case .fill(let selector, let value):
            arguments["action"] = "fill"; arguments["selector"] = selector; arguments["value"] = value
        case .scroll(let selector, let deltaX, let deltaY):
            arguments["action"] = "scroll"; arguments["selector"] = selector ?? NSNull()
            arguments["deltaX"] = deltaX; arguments["deltaY"] = deltaY
        }
        let result = try await runAgentScript(FramePageScripts.interact, arguments: arguments)
        if let message = result["error"] as? String { throw ControlCommandError(message) }
        return result
    }

    /// 在独立脚本世界中执行函数体，返回对象结果。网页无响应时 10 秒后失败。
    private func runAgentScript(_ body: String, arguments: [String: Any]) async throws -> [String: Any] {
        let value: Any? = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            func finish(_ result: Result<Any?, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Self.agentWorld) { result in
                finish(result.map { $0 as Any? }.mapError { ControlCommandError("页面脚本执行失败：\($0.localizedDescription)") })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(.failure(ControlCommandError("页面没有响应"))) }
        }
        guard let object = value as? [String: Any] else { throw ControlCommandError("页面脚本返回了无法识别的结果") }
        return object
    }

    @objc private func openExternal() {
        guard let previewURL else { return }
        let current = webView.url.flatMap { isPreviewOrigin($0) ? $0 : nil } ?? previewURL
        NSWorkspace.shared.open(current)
    }

    func reload() {
        timeout?.cancel()
        rejectedResponse = false
        isReady = false
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
        isReady = false
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
        console.append(level: "info", source: "atlas", message: "页面已加载：\(webView.url?.absoluteString ?? "")")
        isReady = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        if rejectedResponse { rejectedResponse = false; return }
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
            rejectedResponse = true
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
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, isPreviewOrigin(url) else { return }
        switch message.name {
        case "atlasExit":
            canvas?.pageRequestedExit(definition.id)
        case "atlasConsole":
            guard let body = message.body as? [String: Any], let level = body["level"] as? String,
                  let source = body["source"] as? String, let text = body["message"] as? String else { return }
            console.append(level: level, source: source, message: text)
        default: break
        }
    }

    /// Frames read like a design board, so the page and its scroll containers show no scrollbar; scrolling still works.
    private static let hideScrollbarsScript = """
    (() => {
      const style = document.createElement('style');
      style.textContent = '*{scrollbar-width:none!important}*::-webkit-scrollbar{display:none!important}';
      document.documentElement.appendChild(style);
    })();
    """

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
