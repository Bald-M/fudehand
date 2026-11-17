import AppKit
import Foundation
import Testing
@preconcurrency import WebKit
@testable import AtlasApp
@testable import AtlasCore

/// 加载一个与预览同源的测试页面，等待加载完成。
@MainActor private func loadedFrame(_ html: String) async throws -> PreviewFrameView {
    let definition = Frame(id: "m", title: "手机", platform: "mobile", path: "/", width: 390, height: 600, x: 0, y: 0)
    let frame = PreviewFrameView(frame: definition, baseURL: "http://127.0.0.1:9/")
    let web = try #require(frame.pageView as? WKWebView)
    web.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:9/"))
    for _ in 0..<50 where !frame.isReady { try await Task.sleep(for: .milliseconds(100)) }
    #expect(frame.isReady)
    return frame
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
}

@MainActor private func failure(_ action: FrameAction, in frame: PreviewFrameView) async -> String? {
    do { _ = try await frame.interact(action); return nil } catch { return error.localizedDescription }
}

@Test @MainActor func frameCollectsConsoleOutputAndUncaughtErrors() async throws {
    let frame = try await loadedFrame("""
    <script>
    console.log('你好', {a: 1});
    console.warn('注意');
    setTimeout(() => { throw new Error('炸了') });
    setTimeout(() => Promise.reject(new Error('拒绝了')));
    </script>
    """)
    defer { frame.dispose() }
    try await waitFor { frame.console.recent(10).count >= 5 }
    let entries = frame.console.recent(10)
    #expect(entries.contains { $0.source == "atlas" && $0.message.hasPrefix("页面已加载") })
    #expect(entries.contains { $0.level == "log" && $0.source == "console" && $0.message == #"你好 {"a":1}"# })
    #expect(entries.contains { $0.level == "warn" && $0.message == "注意" })
    #expect(entries.contains { $0.level == "error" && $0.source == "exception" && $0.message.contains("炸了") })
    #expect(entries.contains { $0.level == "error" && $0.source == "exception" && $0.message.contains("拒绝了") })
}

@Test @MainActor func frameReadsAVisibleOutlineWithSelectors() async throws {
    let frame = try await loadedFrame("""
    <title>表单页</title>
    <main><h1>注册</h1><p>填写你的邮箱。</p>
    <label for=mail>邮箱</label><input id=mail placeholder="name@example.com" value="a@b.c">
    <button>提交</button><div style="display:none">隐藏文字</div></main>
    """)
    defer { frame.dispose() }
    let page = try await frame.readPage()
    #expect(page["title"] as? String == "表单页")
    let outline = try #require(page["outline"] as? String)
    #expect(outline.contains("h1 注册"))
    #expect(outline.contains("填写你的邮箱。"))
    #expect(outline.contains(#"input[type=text] "邮箱" = "a@b.c" → #mail"#))
    #expect(outline.contains(#"button "提交" → "#))
    #expect(!outline.contains("隐藏文字"))
    #expect(page["truncated"] as? Bool == false)
}

@Test @MainActor func frameInteractsByClickingFillingAndScrolling() async throws {
    let frame = try await loadedFrame("""
    <button id=go onclick="this.dataset.count = (+this.dataset.count || 0) + 1">加一</button>
    <input id=name oninput="document.title = 'input:' + this.value" onchange="document.body.dataset.changed = this.value">
    <div style="height:3000px"></div><p id=end>底部</p>
    """)
    defer { frame.dispose() }
    let web = try #require(frame.pageView as? WKWebView)
    _ = try await frame.interact(.click(selector: "#go"))
    #expect(try await web.evaluateJavaScript("document.getElementById('go').dataset.count") as? String == "1")
    _ = try await frame.interact(.fill(selector: "#name", value: "小明"))
    #expect(try await web.evaluateJavaScript("document.title") as? String == "input:小明")
    #expect(try await web.evaluateJavaScript("document.body.dataset.changed") as? String == "小明")
    let scrolled = try await frame.interact(.scroll(selector: nil, deltaX: 0, deltaY: 500))
    #expect(scrolled["scrollY"] as? Double == 500)
    let revealed = try await frame.interact(.scroll(selector: "#end", deltaX: 0, deltaY: 0))
    #expect((revealed["scrollY"] as? Double ?? 0) > 2000)
}

@Test @MainActor func frameInteractionReportsChineseErrorsAndStaysOnThePreview() async throws {
    let frame = try await loadedFrame("""
    <a id=out href="https://example.com/">外站</a><a id=blank href="/b" target=_blank>新窗口</a><div id=box>盒子</div>
    """)
    defer { frame.dispose() }
    #expect(await failure(.click(selector: "#nope"), in: frame) == "找不到元素：#nope")
    #expect(await failure(.click(selector: "[["), in: frame) == "选择器无效：[[")
    #expect(await failure(.click(selector: "#out"), in: frame) == "不能点击指向其他站点的链接：https://example.com/")
    #expect(await failure(.click(selector: "#blank"), in: frame) == "不能点击在新窗口打开的链接：http://127.0.0.1:9/b")
    #expect(await failure(.fill(selector: "#box", value: "x"), in: frame) == "元素不能填写：#box")
}

/// SVG 链接、图像热区和页面脚本代为点击的外站链接，都不能借 Agent 交互把画框带离作品。
@Test @MainActor func agentClicksNeverOpenExternalSites() async throws {
    let frame = try await loadedFrame("""
    <svg width=100 height=40><a id=svg href="https://example.com/s"><text y=20>外</text></a></svg>
    <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" usemap="#m" width=40 height=40>
    <map name=m><area id=area shape=rect coords="0,0,40,40" href="https://example.com/a"></map>
    <a id=hidden href="https://example.com/h" style="display:none">隐藏</a>
    <button id=relay onclick="document.getElementById('hidden').click()">转发</button>
    """)
    defer { frame.dispose() }
    #expect(await failure(.click(selector: "#svg"), in: frame) == "不能点击指向其他站点的链接：https://example.com/s")
    #expect(await failure(.click(selector: "#area"), in: frame) == "不能点击指向其他站点的链接：https://example.com/a")
    _ = try await frame.interact(.click(selector: "#relay"))
    try await Task.sleep(for: .milliseconds(300))
    #expect((frame.pageView as? WKWebView)?.url?.host == "127.0.0.1")
}
