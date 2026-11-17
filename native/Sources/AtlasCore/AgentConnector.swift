import Foundation

/// The connection status of an MCP connector: whether the ui-atlas MCP server is registered in that Agent's user-level configuration.
public enum ConnectorStatus: Equatable, Sendable {
    /// The corresponding CLI cannot be found on this machine.
    case unavailable
    case disconnected
    /// Registered and pointing at this checkout's MCP server.
    case connected
    /// `ui-atlas` is registered, but the command points elsewhere; the associated value is the registered command.
    case elsewhere(String)
}

/// An MCP connector: registers the ui-atlas MCP server in the user-level configuration of an external Agent (Claude Code, Codex), or removes it from there.
public enum AgentConnector: String, CaseIterable, Sendable {
    case claude, codex

    public static let serverName = "ui-atlas"

    public var title: String { self == .claude ? "Claude Code" : "Codex" }
    public var executable: String { self == .claude ? "claude" : "codex" }

    public func addArguments(script: String) -> [String] {
        let scope = self == .claude ? ["--scope", "user"] : []
        return ["mcp", "add"] + scope + [Self.serverName, "--", "node", script]
    }

    public var removeArguments: [String] {
        ["mcp", "remove"] + (self == .claude ? ["--scope", "user"] : []) + [Self.serverName]
    }

    /// Codex reads the status with `mcp get --json`; Claude Code's `mcp get` would start and check the server, so `~/.claude.json` is read directly instead.
    public var statusArguments: [String]? { self == .codex ? ["mcp", "get", Self.serverName, "--json"] : nil }

    /// Looks up the CLI in PATH.
    public func locate(path: String, isExecutable: (String) -> Bool) -> String? {
        path.split(separator: ":").map { "\($0)/\(executable)" }.first(where: isExecutable)
    }

    /// Parses the top-level (user-level) `mcpServers` of `~/.claude.json`.
    public static func claudeStatus(config: Data?, script: String) -> ConnectorStatus {
        guard let config, let root = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any],
              let server = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else { return .disconnected }
        return status(command: server["command"] as? String, args: server["args"] as? [String], script: script)
    }

    /// Parses `codex mcp get ui-atlas --json`; when not registered the command exits with a non-zero status.
    public static func codexStatus(output: Data, exitCode: Int32, script: String) -> ConnectorStatus {
        guard exitCode == 0, let root = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else { return .disconnected }
        let transport = root["transport"] as? [String: Any]
        return status(command: transport?["command"] as? String, args: transport?["args"] as? [String], script: script)
    }

    private static func status(command: String?, args: [String]?, script: String) -> ConnectorStatus {
        let args = args ?? []
        if args.contains(script) { return .connected }
        return .elsewhere(([command ?? ""] + args).filter { !$0.isEmpty }.joined(separator: " "))
    }
}
