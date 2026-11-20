import AppKit
import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// Simulates the codex CLI's user-level configuration: after add, get returns the registration; after remove, it reports not found.
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
            guard let registered else { return CommandResult(exitCode: 1, output: Data(), error: "No MCP server named 'fudehand' found.") }
            let json = try! JSONSerialization.data(withJSONObject: ["name": "fudehand", "transport": ["command": registered[0], "args": Array(registered.dropFirst())]])
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
    #expect(await codex.calls.contains(["mcp", "add", "fudehand", "--", "node", "/repo/scripts/mcp-server.mjs"]))

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
    try Data(#"{"mcpServers":{"fudehand":{"command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8).write(to: config)
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
    try Data(#"{"mcpServers":{"fudehand":{"command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8)
        .write(to: directory.appendingPathComponent(".claude.json"))
    let model = ConnectorsModel(root: URL(fileURLWithPath: "/repo"), runtime: nil, inherited: ["PATH": "/tools", "CLAUDE_CONFIG_DIR": directory.path],
                                isExecutable: { $0 == "/tools/claude" }) { _, _, _ in CommandResult(exitCode: 0, output: Data(), error: "") }
    await model.refresh()
    #expect(model.entries[.claude]?.status == .connected)
}

@MainActor
private func makeDeepseekModel(home: URL, node: String? = "/opt/node/bin/node", installed: Bool = true) -> ConnectorsModel {
    ConnectorsModel(root: URL(fileURLWithPath: "/repo"), runtime: WorkspaceLocation(root: "/repo", node: node, path: "/tools"),
                    inherited: ["PATH": "/usr/bin", "DSH_HOME": home.path], claudeConfig: URL(fileURLWithPath: "/nonexistent/.claude.json"),
                    isExecutable: { installed && $0 == "/tools/dsh" }) { _, _, _ in
        preconditionFailure("DeepSeek Harness is configured through its patch file, not a command")
    }
}

@Test @MainActor func connectorsConnectAndDisconnectDeepseek() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let patch = home.appendingPathComponent("cordis.patch.yml")
    let own = "# mine\n- id: locale\n  config:\n    preference: zh\n"
    try Data(own.utf8).write(to: patch)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: patch.path)
    // The credentials file must never be read or rewritten.
    let credentials = home.appendingPathComponent(".credentials.yaml")
    try Data("token: secret\n".utf8).write(to: credentials)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: credentials.path)

    let model = makeDeepseekModel(home: home)
    await model.refresh()
    #expect(model.entries[.deepseek]?.status == .disconnected)

    await model.connect(.deepseek)
    #expect(model.entries[.deepseek] == .init(status: .connected, busy: false, error: nil))
    let written = try String(contentsOf: patch, encoding: .utf8)
    #expect(written.hasPrefix(own))
    #expect(written.contains(#"command: "/opt/node/bin/node""#) && written.contains(#"args: ["/repo/scripts/mcp-server.mjs"]"#))
    #expect(try FileManager.default.attributesOfItem(atPath: patch.path)[.posixPermissions] as? Int == 0o600)

    await model.disconnect(.deepseek)
    #expect(model.entries[.deepseek] == .init(status: .disconnected, busy: false, error: nil))
    #expect(try String(contentsOf: patch, encoding: .utf8) == own)
    #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted() == [".credentials.yaml", "cordis.patch.yml"])
}

@Test @MainActor func connectorsCreateAndDeleteTheDeepseekHomePatch() async throws {
    // DSH_HOME does not exist yet: connecting creates it, disconnecting deletes the file it created.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let patch = home.appendingPathComponent("cordis.patch.yml")
    // Without a recorded Node path the entry falls back to `node`.
    let model = makeDeepseekModel(home: home, node: nil)
    await model.connect(.deepseek)
    #expect(model.entries[.deepseek]?.status == .connected)
    #expect(try String(contentsOf: patch, encoding: .utf8).contains(#"command: "node""#))
    #expect(try FileManager.default.attributesOfItem(atPath: patch.path)[.posixPermissions] as? Int == 0o600)

    await model.disconnect(.deepseek)
    #expect(model.entries[.deepseek]?.status == .disconnected)
    #expect(!FileManager.default.fileExists(atPath: patch.path))
}

@Test @MainActor func connectorsReportDeepseekAsUnavailableOrFailing() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let missing = makeDeepseekModel(home: home, installed: false)
    await missing.refresh()
    #expect(missing.entries[.deepseek] == .init(status: .unavailable, busy: false, error: nil))

    // DSH_HOME is a file, so the patch cannot be written.
    try Data().write(to: home)
    let model = makeDeepseekModel(home: home)
    await model.connect(.deepseek)
    #expect(model.entries[.deepseek]?.status == .disconnected)
    #expect(model.entries[.deepseek]?.error?.hasPrefix("Connection failed: ") == true)
}

@Test @MainActor func connectorsEditTheTargetOfASymlinkedDeepseekPatch() async throws {
    // Dotfile managers keep the real file elsewhere and link it into DSH_HOME: the link must survive.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let home = directory.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("dotfiles.yml")
    try Data("- id: locale\n".utf8).write(to: target)
    let link = home.appendingPathComponent("cordis.patch.yml")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let model = makeDeepseekModel(home: home)
    await model.connect(.deepseek)
    #expect(model.entries[.deepseek]?.status == .connected)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8).contains("serverName: fudehand"))
}

@Test @MainActor func everyConnectorAndChatProviderHasAnIconTheSystemCanDraw() throws {
    let icons = try AgentConnector.allCases.map { ("\($0)", try #require(ConnectorIcon.image(for: $0), "\($0)")) }
        + ChatSettings.providers.map { ($0.id, try #require(ConnectorIcon.image(forProvider: $0.id), "\($0.id)")) }
    for (name, image) in icons {
        #expect(image.size == NSSize(width: 24, height: 24))
        // Drawn into a bitmap, the icon must cover part of it, but not all of it (a broken path draws nothing or a stray fill).
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        var painted = 0
        for x in 0..<48 { for y in 0..<48 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { painted += 1 } }
        #expect(painted > 48 * 48 / 10, "\(name)")
        #expect(painted < 48 * 48, "\(name)")
    }
}
