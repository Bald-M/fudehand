import Foundation

/// MCP 连接器的连接状态：ui-atlas MCP server 是否注册在该 Agent 的用户级配置中。
public enum ConnectorStatus: Equatable, Sendable {
    /// 本机找不到对应 CLI。
    case unavailable
    case disconnected
    /// 已注册且指向本检出目录的 MCP server。
    case connected
    /// 已注册 `ui-atlas`，但命令指向别处；关联值是注册的命令。
    case elsewhere(String)
}

/// MCP 连接器：把 ui-atlas MCP server 注册到外部 Agent（Claude Code、Codex）的用户级配置，或从中移除。
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

    /// Codex 用 `mcp get --json` 读取状态；Claude Code 的 `mcp get` 会启动并检查 server，改为直接读 `~/.claude.json`。
    public var statusArguments: [String]? { self == .codex ? ["mcp", "get", Self.serverName, "--json"] : nil }

    /// 在 PATH 中查找 CLI。
    public func locate(path: String, isExecutable: (String) -> Bool) -> String? {
        path.split(separator: ":").map { "\($0)/\(executable)" }.first(where: isExecutable)
    }

    /// 解析 `~/.claude.json` 顶层（用户级）的 `mcpServers`。
    public static func claudeStatus(config: Data?, script: String) -> ConnectorStatus {
        guard let config, let root = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any],
              let server = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else { return .disconnected }
        return status(command: server["command"] as? String, args: server["args"] as? [String], script: script)
    }

    /// 解析 `codex mcp get ui-atlas --json`；未注册时命令以非零状态退出。
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
