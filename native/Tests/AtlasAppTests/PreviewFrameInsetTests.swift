import AppKit
import Foundation
import Testing
@preconcurrency import WebKit
@testable import AtlasApp
@testable import AtlasCore

/// A frame panned under a full-size-content toolbar keeps its whole CSS viewport: WebKit must not treat the
/// covered strip as an obscured inset and push the page down (#14).
@Test @MainActor func aFrameUnderTheToolbarKeepsItsFullViewport() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
    let toolbar = NSToolbar(identifier: "test")
    window.toolbar = toolbar
    let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
    window.contentView = container
    #expect(window.contentLayoutRect.maxY < container.bounds.maxY, "窗口内容区应延伸到工具栏下方")
    let definition = Frame(id: "m", title: "手机", platform: "mobile", path: "/", width: 390, height: 844, x: 0, y: 0)
    let frame = PreviewFrameView(frame: definition, baseURL: "http://127.0.0.1:9/")
    // Top edge sits above the content layout rect, i.e. under the toolbar.
    frame.frame = NSRect(x: 20, y: container.bounds.maxY - 500, width: 390, height: 844 + CanvasGeometry.headerHeight)
    container.addSubview(frame)
    container.layoutSubtreeIfNeeded()
    // WebKit recomputes automatic insets on the next run loop pass.
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let web = try #require(frame.pageView as? WKWebView)
    let inset = (web.value(forKey: "_topContentInset") as? NSNumber)?.doubleValue
    #expect(inset == 0)
    frame.dispose()
}
