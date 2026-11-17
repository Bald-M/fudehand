import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

/// 模拟 codex CLI 的用户级配置：add 后 get 返回注册内容，remove 后报未找到。
private actor FakeCodex {
    var registered: [String]?
    var calls: [[String]] = []
    var failNextAdd = false

    func run(_ arguments: [String]) -> CommandResult {
        calls.append(arguments)
        switch arguments.prefix(2) {
        case ["mcp", "add"]:
            if failNextAdd { failNextAdd = false; return CommandResult(exitCode: 1, output: Data(), error: "Error: config is read-only") }
            registered = Array(arguments.drop { $0 != "--" }.dropFirst()); return CommandResult(exitCode: 0, output: Data(), error: "")
        case ["mcp", "remove"]:
            registered = nil; return CommandResult(exitCode: 0, output: Data(), error: "")
        default:
            guard let registered else { return CommandResult(exitCode: 1, output: Data(), error: "No MCP server named 'ui-atlas' found.") }
            let json = try! JSONSerialization.data(withJSONObject: ["name": "ui-atlas", "transport": ["command": registered[0], "args": Array(registered.dropFirst())]])
            return CommandResult(exitCode: 0, output: json, error: "")
        }
    }
    func failAdd() { failNextAdd = true }
}

@MainActor
private func makeModel(_ codex: FakeCodex, claudeConfig: URL, root: URL? = URL(fileURLWithPath: "/repo")) -> ConnectorsModel {
    ConnectorsModel(root: root, runtime: WorkspaceLocation(root: "/repo", node: nil, path: "/tools"), inherited: ["PATH": "/usr/bin"],
                    claudeConfig: claudeConfig, isExecutable: { $0 == "/tools/codex" }) { executable, arguments, environment in
        precondition(executable == "/tools/codex" && environment["PATH"]?.hasPrefix("/tools:/usr/bin") == true)
        return await codex.run(arguments)
    }
}

@Test @MainActor func connectorsConnectAndDisconnectCodex() async {
    let codex = FakeCodex()
    let model = makeModel(codex, claudeConfig: URL(fileURLWithPath: "/nonexistent/.claude.json"))
    await model.refresh()
    #expect(model.entries[.codex]?.status == .disconnected)
    #expect(model.entries[.claude]?.status == .unavailable)

    await model.connect(.codex)
    #expect(model.entries[.codex] == .init(status: .connected, busy: false, error: nil))
    #expect(await codex.calls.contains(["mcp", "add", "ui-atlas", "--", "node", "/repo/scripts/mcp-server.mjs"]))

    await model.disconnect(.codex)
    #expect(model.entries[.codex]?.status == .disconnected)
}

@Test @MainActor func connectorsReportFailuresWithoutChangingStatus() async {
    let codex = FakeCodex()
    await codex.failAdd()
    let model = makeModel(codex, claudeConfig: URL(fileURLWithPath: "/nonexistent/.claude.json"))
    await model.refresh()
    await model.connect(.codex)
    #expect(model.entries[.codex]?.status == .disconnected)
    #expect(model.entries[.codex]?.busy == false)
    #expect(model.entries[.codex]?.error == "Connection failed: Error: config is read-only")
}

@Test @MainActor func connectorsReadClaudeUserConfig() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent(".claude.json")
    try Data(#"{"mcpServers":{"ui-atlas":{"command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8).write(to: config)
    let model = ConnectorsModel(root: URL(fileURLWithPath: "/repo"), runtime: nil, inherited: ["PATH": "/tools"], claudeConfig: config,
                                isExecutable: { $0 == "/tools/claude" }) { _, _, _ in CommandResult(exitCode: 0, output: Data(), error: "") }
    await model.refresh()
    #expect(model.entries[.claude]?.status == .connected)
    #expect(model.entries[.codex]?.status == .unavailable)
}

@Test @MainActor func connectorsShowCodexDetectionFailures() async {
    let model = ConnectorsModel(root: URL(fileURLWithPath: "/repo"), runtime: nil, inherited: ["PATH": "/tools"],
                                claudeConfig: URL(fileURLWithPath: "/nonexistent/.claude.json"), isExecutable: { $0 == "/tools/codex" }) { _, _, _ in
        CommandResult(exitCode: 1, output: Data(), error: "Error: invalid config.toml")
    }
    await model.refresh()
    #expect(model.entries[.codex]?.status == .disconnected)
    #expect(model.entries[.codex]?.error == "Could not check the connection status: Error: invalid config.toml")
}

@Test @MainActor func connectorsFollowClaudeConfigDir() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"mcpServers":{"ui-atlas":{"command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8)
        .write(to: directory.appendingPathComponent(".claude.json"))
    let model = ConnectorsModel(root: URL(fileURLWithPath: "/repo"), runtime: nil, inherited: ["PATH": "/tools", "CLAUDE_CONFIG_DIR": directory.path],
                                isExecutable: { $0 == "/tools/claude" }) { _, _, _ in CommandResult(exitCode: 0, output: Data(), error: "") }
    await model.refresh()
    #expect(model.entries[.claude]?.status == .connected)
}
