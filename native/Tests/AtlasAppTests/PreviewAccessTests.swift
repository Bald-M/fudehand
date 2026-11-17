import AppKit
import Foundation
import Testing
@preconcurrency import WebKit
@testable import AtlasApp
@testable import AtlasCore

/// The preview services accept only requests carrying the launch token cookie; the frames get it for every
/// loopback host a catalog may use (#36).
@Test @MainActor func accessCookiesCoverEveryLoopbackHost() throws {
    let cookies = PreviewSession.accessCookies(token: "abc")
    #expect(Set(cookies.map(\.domain)) == ["127.0.0.1", "localhost", "::1"])
    for cookie in cookies {
        #expect(cookie.name == "ui_atlas_preview" && cookie.value == "abc" && cookie.path == "/")
        #expect(cookie.isSessionOnly)
    }
    let request = try #require(HTTPCookie.requestHeaderFields(with: cookies.filter { $0.domain == "127.0.0.1" })["Cookie"])
    #expect(request == "ui_atlas_preview=abc")
}

/// Works open only in the App: the frame header has no button that hands the page to a browser (#36).
@Test @MainActor func frameHeaderHasNoBrowserButton() {
    let definition = Frame(id: "m", title: "手机", platform: "mobile", path: "/", width: 390, height: 844, x: 0, y: 0)
    let frame = PreviewFrameView(frame: definition, baseURL: "http://127.0.0.1:9/")
    defer { frame.dispose() }
    frame.frame = NSRect(x: 0, y: 0, width: 390, height: 844 + CanvasGeometry.headerHeight)
    frame.layoutSubtreeIfNeeded()
    #expect(frame.control(at: NSPoint(x: 390 - 24, y: 22)) == nil)
    let buttons = frame.subviews.compactMap { $0 as? NSButton }
    #expect(buttons.map(\.title) == ["重新加载"])
}

/// Links, `window.open` and `target=_blank` that leave the work's preview service keep the frame where it is.
@Test @MainActor func outsideNavigationStaysInTheFrame() async throws {
    let definition = Frame(id: "m", title: "手机", platform: "mobile", path: "/", width: 390, height: 844, x: 0, y: 0)
    let frame = PreviewFrameView(frame: definition, baseURL: "http://127.0.0.1:9/")
    defer { frame.dispose() }
    let web = try #require(frame.pageView as? WKWebView)
    let base = try #require(URL(string: "http://127.0.0.1:9/"))
    web.loadHTMLString("""
    <a id=same href='https://example.invalid/'>外链</a>
    <a id=blank target=_blank href='https://example.invalid/'>新窗口</a>
    """, baseURL: base)
    var loaded = false
    for _ in 0..<50 where !loaded {
        try await Task.sleep(for: .milliseconds(100))
        loaded = ((try? await web.evaluateJavaScript("!!document.getElementById('blank')")) as? Bool) ?? false
    }
    #expect(loaded)
    _ = try? await web.evaluateJavaScript("document.getElementById('same').click(); document.getElementById('blank').click(); window.open('https://example.invalid/'); 1")
    try await Task.sleep(for: .milliseconds(500))
    #expect(web.url?.host == "127.0.0.1")
    #expect(((try? await web.evaluateJavaScript("!!document.getElementById('same')")) as? Bool) == true)
}

/// The launcher gets the token through its environment, and a work is reported ready only once the frames'
/// cookie store holds the same token, so a frame never loads without it.
@Test @MainActor func aWorkIsReadyOnlyAfterTheFramesHaveTheLaunchToken() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-access-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try """
    import { writeFileSync } from 'node:fs'
    import { createInterface } from 'node:readline'
    writeFileSync(new URL('./token', import.meta.url), process.env.UI_ATLAS_PREVIEW_TOKEN ?? '')
    process.stdout.write('UI_ATLAS_LISTENING\\n')
    createInterface({ input: process.stdin }).on('line', line => process.stdout.write(`UI_ATLAS_READY ${line.split(' ')[1]}\\n`))
    """.write(to: root.appendingPathComponent("scripts/native-preview.mjs"), atomically: true, encoding: .utf8)
    // A private store: other tests start sessions in parallel and write their own tokens to the default one.
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let session = PreviewSession(cookieStore: dataStore.httpCookieStore)
    session.start(root: root, runtime: WorkspaceLocation(root: root.path, node: nil, path: nil))
    session.request("ok")
    for _ in 0..<100 where session.phase(for: "ok") != .ready { try await Task.sleep(nanoseconds: 30_000_000) }
    #expect(session.phase(for: "ok") == .ready)
    let token = try String(contentsOf: root.appendingPathComponent("scripts/token"), encoding: .utf8)
    #expect(token.count == 64)
    let cookies = await dataStore.httpCookieStore.allCookies()
    #expect(cookies.contains { $0.name == "ui_atlas_preview" && $0.domain == "127.0.0.1" && $0.value == token })
    await session.stop()
}
