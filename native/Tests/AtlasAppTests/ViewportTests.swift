import AppKit
import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

@Test @MainActor func resizingAfterSwitchingToANewProjectPreservesTheUsersViewport() {
    let preview = Preview(cwd: "examples/demo", command: ["pnpm", "dev"], port: 4401, baseUrl: "http://127.0.0.1:4401/")
    let frame = Frame(id: "home", title: "首页", platform: "web", path: "/", width: 1440, height: 900, x: 0, y: 0)
    let first = Project(id: "first", title: "作品一", subtitle: "", description: "", author: "", sourceUrl: nil,
                        framework: "HTML", tags: [], enabled: true, layoutVersion: 1, preview: preview, frames: [frame])
    var second = first
    second.id = "second"
    let store = AtlasStore()
    store.select(first)
    store.resize(CGSize(width: 1000, height: 700))
    store.select(second)
    store.zoom(1)
    let chosenViewport = store.viewport
    store.resize(CGSize(width: 900, height: 650))
    #expect(store.viewport == chosenViewport)
}

@Test @MainActor func spacePanningEndsWhenTheWindowLosesFocus() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas = AtlasCanvasView(frame: window.contentLayoutRect)
    window.contentView = canvas
    canvas.spaceHeld = true
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(!canvas.spaceHeld)
    canvas.spaceHeld = true
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    #expect(!canvas.spaceHeld)
    canvas.dispose()
}

@Test @MainActor func aLauncherThatExitsImmediatelyReportsItsFinalError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let message = "[界面图鉴] 端口 4401 已被占用"
    // The launcher exits first; a grandchild still holding the pipe writes the last line afterwards,
    // so the failure must wait for end of output instead of using what arrived before the exit.
    let grandchild = "setTimeout(() => process.stderr.write(\(String(reflecting: message))), 300)"
    try """
    import { spawn } from 'node:child_process'
    process.stderr.write('日志\\n')
    spawn(process.execPath, ['-e', \(String(reflecting: grandchild))], { stdio: ['ignore', 'inherit', 'inherit'], detached: true }).unref()
    process.exitCode = 1
    """.write(to: root.appendingPathComponent("scripts/native-preview.mjs"), atomically: true, encoding: .utf8)
    let session = PreviewSession()
    session.start(root: root, runtime: WorkspaceLocation(root: root.path, node: nil, path: nil))
    for _ in 0..<100 {
        if case .failed = session.phase { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard case .failed(let detail) = session.phase else { Issue.record("会话未报告失败：\(session.phase)"); return }
    #expect(detail.hasSuffix(message))
}
