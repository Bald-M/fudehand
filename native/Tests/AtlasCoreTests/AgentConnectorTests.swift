import Foundation
import Testing
import AtlasCore

private let script = "/repo/scripts/mcp-server.mjs"

@Test func agentConnectorBuildsUserScopeCommands() {
    #expect(AgentConnector.claude.addArguments(script: script) == ["mcp", "add", "--scope", "user", "ui-atlas", "--", "node", script])
    #expect(AgentConnector.claude.removeArguments == ["mcp", "remove", "--scope", "user", "ui-atlas"])
    #expect(AgentConnector.codex.addArguments(script: script) == ["mcp", "add", "ui-atlas", "--", "node", script])
    #expect(AgentConnector.codex.removeArguments == ["mcp", "remove", "ui-atlas"])
    #expect(AgentConnector.codex.statusArguments == ["mcp", "get", "ui-atlas", "--json"])
    #expect(AgentConnector.allCases.map(\.title) == ["Claude Code", "Codex"])
}

@Test func claudeStatusReadsTheUserScopeServer() {
    let connected = Data(#"{"mcpServers":{"ui-atlas":{"type":"stdio","command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: connected, script: script) == .connected)

    let elsewhere = Data(#"{"mcpServers":{"ui-atlas":{"command":"node","args":["/other/scripts/mcp-server.mjs"]}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: elsewhere, script: script) == .elsewhere("node /other/scripts/mcp-server.mjs"))

    // 只看用户级配置；项目级配置在 projects 下，不算已连接。
    let projectOnly = Data(#"{"projects":{"/repo":{"mcpServers":{"ui-atlas":{"command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: projectOnly, script: script) == .disconnected)
    #expect(AgentConnector.claudeStatus(config: nil, script: script) == .disconnected)
    #expect(AgentConnector.claudeStatus(config: Data("not json".utf8), script: script) == .disconnected)
}

@Test func codexStatusReadsMcpGetOutput() {
    let connected = Data(#"{"name":"ui-atlas","enabled":true,"transport":{"type":"stdio","command":"node","args":["/repo/scripts/mcp-server.mjs"]}}"#.utf8)
    #expect(AgentConnector.codexStatus(output: connected, exitCode: 0, script: script) == .connected)

    let elsewhere = Data(#"{"name":"ui-atlas","transport":{"type":"stdio","command":"node","args":["/old/scripts/mcp-server.mjs","--root","/old"]}}"#.utf8)
    #expect(AgentConnector.codexStatus(output: elsewhere, exitCode: 0, script: script) == .elsewhere("node /old/scripts/mcp-server.mjs --root /old"))

    #expect(AgentConnector.codexStatus(output: Data("Error: No MCP server named 'ui-atlas' found.".utf8), exitCode: 1, script: script) == .disconnected)
}

@Test func agentConnectorLocatesTheCliOnThePath() {
    let found = AgentConnector.codex.locate(path: "/missing:/opt/homebrew/bin:/usr/bin") { $0 == "/opt/homebrew/bin/codex" }
    #expect(found == "/opt/homebrew/bin/codex")
    #expect(AgentConnector.claude.locate(path: "/usr/bin::/bin") { _ in false } == nil)
}
