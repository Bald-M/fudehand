import Foundation
import Testing
import FudehandCore

private let script = "/repo/scripts/mcp-server.mjs"

@Test func agentConnectorBuildsUserScopeCommands() {
    #expect(AgentConnector.claude.addArguments(node: "/opt/homebrew/bin/node", script: script)
            == ["mcp", "add", "--scope", "user", "fudehand", "--", "/opt/homebrew/bin/node", script])
    #expect(AgentConnector.claude.removeArguments == ["mcp", "remove", "--scope", "user", "fudehand"])
    #expect(AgentConnector.codex.addArguments(node: "/opt/homebrew/bin/node", script: script)
            == ["mcp", "add", "fudehand", "--", "/opt/homebrew/bin/node", script])
    #expect(AgentConnector.codex.removeArguments == ["mcp", "remove", "fudehand"])
    #expect(AgentConnector.codex.statusArguments == ["mcp", "get", "fudehand", "--json"])
    #expect(AgentConnector.allCases.map(\.title) == ["Claude Code", "Codex", "DeepSeek Harness"])
}

@Test func claudeStatusReadsTheUserScopeServer() {
    let connected = Data(#"{"mcpServers":{"fudehand":{"type":"stdio","command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: connected, script: script) == .connected)

    let elsewhere = Data(#"{"mcpServers":{"fudehand":{"command":"node","args":["/other/scripts/mcp-server.mjs"]}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: elsewhere, script: script) == .elsewhere("node /other/scripts/mcp-server.mjs"))

    // Only the user-level configuration counts; project-level configuration lives under projects and does not count as connected.
    let projectOnly = Data(#"{"projects":{"/repo":{"mcpServers":{"fudehand":{"command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: projectOnly, script: script) == .disconnected)
    #expect(AgentConnector.claudeStatus(config: nil, script: script) == .disconnected)
    #expect(AgentConnector.claudeStatus(config: Data("not json".utf8), script: script) == .disconnected)
}

@Test func codexStatusReadsMcpGetOutput() {
    let connected = Data(#"{"name":"fudehand","enabled":true,"transport":{"type":"stdio","command":"node","args":["/repo/scripts/mcp-server.mjs"]}}"#.utf8)
    #expect(AgentConnector.codexStatus(output: connected, exitCode: 0, script: script) == .connected)

    let elsewhere = Data(#"{"name":"fudehand","transport":{"type":"stdio","command":"node","args":["/old/scripts/mcp-server.mjs","--root","/old"]}}"#.utf8)
    #expect(AgentConnector.codexStatus(output: elsewhere, exitCode: 0, script: script) == .elsewhere("node /old/scripts/mcp-server.mjs --root /old"))

    #expect(AgentConnector.codexStatus(output: Data("Error: No MCP server named 'fudehand' found.".utf8), exitCode: 1, script: script) == .disconnected)
}

@Test func agentConnectorLocatesTheCliOnThePath() {
    let found = AgentConnector.codex.locate(path: "/missing:/opt/homebrew/bin:/usr/bin") { $0 == "/opt/homebrew/bin/codex" }
    #expect(found == "/opt/homebrew/bin/codex")
    #expect(AgentConnector.claude.locate(path: "/usr/bin::/bin") { _ in false } == nil)
}

private let deepseekBlock = """
# >>> fudehand MCP connector (managed by fudehand; change it in the MCP Connectors window) >>>
- insert:
    - id: mcp-fudehand
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: fudehand
        transport: stdio
        command: "/opt/node/bin/node"
        args: ["/repo/scripts/mcp-server.mjs"]
# <<< fudehand MCP connector <<<

"""

@Test func deepseekConnectingWritesAManagedBlockIntoTheHomePatch() {
    // No home patch yet: the file is just the block.
    #expect(AgentConnector.deepseekConnecting(patch: nil, node: "/opt/node/bin/node", script: script) == deepseekBlock)

    // The user's own entries and comments are kept byte for byte, and the block is appended after them.
    let own = "# mine\n- id: locale\n  config:\n    preference: !!js process.env.LANG\n"
    #expect(AgentConnector.deepseekConnecting(patch: own, node: "/opt/node/bin/node", script: script) == own + deepseekBlock)
    #expect(AgentConnector.deepseekConnecting(patch: "- id: locale", node: "/opt/node/bin/node", script: script) == "- id: locale\n" + deepseekBlock)

    // An empty list written as `[]` cannot be followed by block entries, so it is replaced.
    #expect(AgentConnector.deepseekConnecting(patch: "# mine\n[]\n", node: "/opt/node/bin/node", script: script) == "# mine\n" + deepseekBlock)

    // Connecting again replaces the old block rather than adding a second server with the same name.
    let stale = AgentConnector.deepseekConnecting(patch: own, node: "node", script: "/old/scripts/mcp-server.mjs")
    #expect(AgentConnector.deepseekConnecting(patch: stale, node: "/opt/node/bin/node", script: script) == own + deepseekBlock)
}

@Test func deepseekStatusReadsTheManagedBlock() {
    #expect(AgentConnector.deepseekStatus(patch: nil, script: script) == .disconnected)
    #expect(AgentConnector.deepseekStatus(patch: "- id: locale\n", script: script) == .disconnected)
    #expect(AgentConnector.deepseekStatus(patch: "- id: locale\n" + deepseekBlock, script: script) == .connected)
    #expect(AgentConnector.deepseekStatus(patch: deepseekBlock, script: "/other/scripts/mcp-server.mjs")
        == .elsewhere("/opt/node/bin/node /repo/scripts/mcp-server.mjs"))

    // Paths with spaces and quotes survive the round trip.
    let odd = "/Users/a \"b\"/ui atlas/scripts/mcp-server.mjs"
    #expect(AgentConnector.deepseekStatus(patch: AgentConnector.deepseekConnecting(patch: nil, node: "node", script: odd), script: odd) == .connected)
}

@Test func deepseekDisconnectingRemovesOnlyTheManagedBlock() {
    let own = "# mine\n- id: locale\n  config:\n    preference: zh\n"
    #expect(AgentConnector.deepseekDisconnecting(patch: own + deepseekBlock) == own)
    #expect(AgentConnector.deepseekDisconnecting(patch: deepseekBlock + own) == own)
    #expect(AgentConnector.deepseekDisconnecting(patch: own) == own)

    // dsh refuses to start on a patch file that is empty or holds only comments: delete the file, or leave an empty list under the user's comments.
    #expect(AgentConnector.deepseekDisconnecting(patch: deepseekBlock) == nil)
    #expect(AgentConnector.deepseekDisconnecting(patch: "# mine\n" + deepseekBlock) == "# mine\n[]\n")
}

@Test func deepseekIsLocatedInTheAppBundleWhenNotOnThePath() {
    let bundled = "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
    #expect(AgentConnector.deepseek.locate(path: "/usr/bin") { $0 == bundled } == bundled)
    #expect(AgentConnector.deepseek.locate(path: "/tools:/usr/bin") { $0 == "/tools/dsh" || $0 == bundled } == "/tools/dsh")
    #expect(AgentConnector.deepseek.locate(path: "/usr/bin") { _ in false } == nil)
    #expect(AgentConnector.codex.locate(path: "/usr/bin") { $0 == bundled } == nil)
}

@Test func deepseekPatchEditingKeepsWindowsLineEndings() {
    let own = "# mine\r\n- id: locale\r\n"
    let connected = AgentConnector.deepseekConnecting(patch: own, node: "/opt/node/bin/node", script: script)
    #expect(connected == own + deepseekBlock)
    #expect(AgentConnector.deepseekDisconnecting(patch: connected) == own)
    #expect(AgentConnector.deepseekConnecting(patch: "[]\r\n", node: "/opt/node/bin/node", script: script) == deepseekBlock)
    // An editor may have converted the block itself.
    let converted = deepseekBlock.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(AgentConnector.deepseekStatus(patch: own + converted, script: script) == .connected)
    #expect(AgentConnector.deepseekDisconnecting(patch: own + converted) == own)
}

@Test func deepseekBlockNeedsBothMarkers() {
    // A begin marker whose end marker was deleted by hand is not a block: nothing after it may be removed with it.
    let orphan = "# >>> fudehand MCP connector >>>\n- id: locale\n"
    #expect(AgentConnector.deepseekStatus(patch: orphan, script: script) == .disconnected)
    #expect(AgentConnector.deepseekDisconnecting(patch: orphan + deepseekBlock) == orphan)
}

@Test func registrationWithAMissingNodeNeedsUpdating() {
    // Registered with this script but an absolute Node path that no longer exists (an uninstalled nvm version, say): not connected.
    let gone = Data(#"{"mcpServers":{"fudehand":{"command":"/gone/node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: gone, script: script, commandExists: { $0 != "/gone/node" })
        == .elsewhere("/gone/node /repo/scripts/mcp-server.mjs"))
    #expect(AgentConnector.claudeStatus(config: gone, script: script, commandExists: { _ in true }) == .connected)
    // A bare `node` (as older builds registered) is looked up on the Agent's PATH, so it is not checked.
    let bare = Data(#"{"mcpServers":{"fudehand":{"command":"node","args":["/repo/scripts/mcp-server.mjs"]}}}"#.utf8)
    #expect(AgentConnector.claudeStatus(config: bare, script: script, commandExists: { _ in false }) == .connected)
    #expect(AgentConnector.deepseekStatus(patch: deepseekBlock, script: script, commandExists: { _ in false })
        == .elsewhere("/opt/node/bin/node /repo/scripts/mcp-server.mjs"))
}
