import Foundation
import Testing
@testable import AtlasApp

/// 用一个按协议应答的假启动器验证按需启动：`ok` 就绪，其他作品先失败一次、重试后就绪。
@MainActor private func fakeLauncherRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try """
    import { createInterface } from 'node:readline'
    const attempts = new Map()
    process.stdout.write('UI_ATLAS_LISTENING\\n')
    createInterface({ input: process.stdin }).on('line', line => {
      const [, id] = line.split(' ')
      const count = (attempts.get(id) ?? 0) + 1
      attempts.set(id, count)
      process.stderr.write(`日志 ${id} ${count}\\n`)
      if (id === 'ok' || count > 1) setTimeout(() => process.stdout.write(`UI_ATLAS_READY ${id}\\n`), 50)
      // 真实启动器在清理进程组后才报告失败，日志总是先于失败行到达。
      else setTimeout(() => process.stdout.write(`UI_ATLAS_FAILED ${id} ${JSON.stringify('端口 4402 无法使用')}\\n`), 100)
    })
    """.write(to: root.appendingPathComponent("scripts/native-preview.mjs"), atomically: true, encoding: .utf8)
    return root
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 30_000_000)
    }
}

@Test @MainActor func servicesStartOnlyWhenRequestedAndFailuresCanBeRetried() async throws {
    let root = try fakeLauncherRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = PreviewSession()
    #expect(session.phase(for: "ok") == .stopped)
    session.start(root: root, runtime: WorkspaceLocation(root: root.path, node: nil, path: nil))
    session.request("ok")
    #expect(session.phase(for: "ok") == .starting)
    #expect(session.phase(for: "other") == .stopped)
    try await waitFor { session.phase(for: "ok") == .ready }
    #expect(session.phase(for: "ok") == .ready)

    session.request("other")
    try await waitFor { if case .failed = session.phase(for: "other") { return true }; return false }
    guard case .failed(let detail) = session.phase(for: "other") else { Issue.record("未报告失败"); return }
    #expect(detail.hasPrefix("端口 4402 无法使用"))
    #expect(detail.contains("日志 other 1"))
    #expect(session.phase(for: "ok") == .ready)

    // 失败后再次请求即重试。
    session.request("other")
    #expect(session.phase(for: "other") == .starting)
    try await waitFor { session.phase(for: "other") == .ready }
    #expect(session.phase(for: "other") == .ready)

    await session.stop()
    #expect(session.phase(for: "ok") == .stopped)
}
