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

/// An MCP connector: registers the ui-atlas MCP server in the user-level configuration of an external Agent (Claude Code, Codex, DeepSeek Harness), or removes it from there.
public enum AgentConnector: String, CaseIterable, Sendable {
    case claude, codex, deepseek

    public static let serverName = "ui-atlas"

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .deepseek: "DeepSeek Harness"
        }
    }

    public var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .deepseek: "dsh"
        }
    }

    /// Claude Code and Codex only: DeepSeek Harness has no `mcp` subcommand and is configured through its home patch file (see `deepseekConnecting`).
    public func addArguments(script: String) -> [String] {
        let scope = self == .claude ? ["--scope", "user"] : []
        return ["mcp", "add"] + scope + [Self.serverName, "--", "node", script]
    }

    public var removeArguments: [String] {
        ["mcp", "remove"] + (self == .claude ? ["--scope", "user"] : []) + [Self.serverName]
    }

    /// Codex reads the status with `mcp get --json`; Claude Code's `mcp get` would start and check the server, so `~/.claude.json` is read directly instead.
    public var statusArguments: [String]? { self == .codex ? ["mcp", "get", Self.serverName, "--json"] : nil }

    /// Looks up the CLI in PATH. DeepSeek Harness does not put `dsh` on the PATH by default, so its app bundle is checked too.
    public func locate(path: String, isExecutable: (String) -> Bool) -> String? {
        let bundled = self == .deepseek ? ["/Applications", NSHomeDirectory() + "/Applications"]
            .map { $0 + "/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh" } : []
        return (path.split(separator: ":").map { "\($0)/\(executable)" } + bundled).first(where: isExecutable)
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

    // MARK: DeepSeek Harness
    //
    // dsh has no command for registering MCP servers. Every profile applies `$DSH_HOME/cordis.patch.yml` (a top-level YAML list) after its own
    // patch file and reloads it when it changes, so the server is registered there, in a block between two marker comments. The file is edited
    // as text and everything outside the block is kept byte for byte: it may hold `!!js` expressions that a YAML round trip would lose.

    private static let deepseekBegin = "# >>> ui-atlas MCP connector"
    private static let deepseekEnd = "# <<< ui-atlas MCP connector"

    /// The home patch with the ui-atlas block added (replacing an older block); `patch` is nil when the file does not exist.
    public static func deepseekConnecting(patch: String?, node: String, script: String) -> String {
        var lines = deepseekLines(deepseekRemovingBlock(patch ?? ""))
        // An empty list written as `[]` cannot be followed by block entries.
        if lines.filter(deepseekIsContent).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) == ["[]"] { lines.removeAll(where: deepseekIsContent) }
        var base = lines.joined(separator: "\n")
        if !base.isEmpty, base.utf8.last != UInt8(ascii: "\n") { base += "\n" }
        let args = deepseekJSON([script])
        return base + """
        \(deepseekBegin) (managed by ui-atlas; change it in the MCP Connectors window) >>>
        - insert:
            - id: mcp-\(serverName)
              name: "@deepseek-ai/dsh-mcp-client"
              config:
                serverName: \(serverName)
                transport: stdio
                command: \(deepseekJSON([node]).dropFirst().dropLast())
                args: \(args)
        \(deepseekEnd) <<<

        """
    }

    /// The home patch without the ui-atlas block, or nil when nothing else is left and the file should be deleted.
    public static func deepseekDisconnecting(patch: String) -> String? {
        let rest = deepseekRemovingBlock(patch)
        if deepseekLines(rest).contains(where: deepseekIsContent) { return rest }
        if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        // dsh refuses to start on a patch file holding only comments.
        return rest + (rest.utf8.last == UInt8(ascii: "\n") ? "" : "\n") + "[]\n"
    }

    public static func deepseekStatus(patch: String?, script: String) -> ConnectorStatus {
        let lines = deepseekLines(patch ?? "")
        guard let block = deepseekBlock(lines).map({ lines[$0] }) else { return .disconnected }
        // Both values are written as JSON, which is also valid YAML.
        func value(_ key: String) -> [String]? {
            guard let line = block.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { $0.hasPrefix(key) }) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(key.count).utf8), options: .fragmentsAllowed)).flatMap { $0 as? [String] ?? ($0 as? String).map { [$0] } }
        }
        return status(command: value("command: ")?.first, args: value("args: "), script: script)
    }

    /// Splits at line feeds only, so a carriage return stays on its line and Windows line endings survive the edit (Swift treats "\r\n" as one Character).
    private static func deepseekLines(_ patch: String) -> [String] {
        patch.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The block is the end marker and the nearest begin marker above it; a begin marker whose end marker is gone is not a block.
    private static func deepseekBlock(_ lines: [String]) -> ClosedRange<Int>? {
        guard let end = lines.firstIndex(where: { $0.hasPrefix(deepseekEnd) }),
              let begin = lines[..<end].lastIndex(where: { $0.hasPrefix(deepseekBegin) }) else { return nil }
        return begin...end
    }

    private static func deepseekRemovingBlock(_ patch: String) -> String {
        var lines = deepseekLines(patch)
        guard let block = deepseekBlock(lines) else { return patch }
        lines.removeSubrange(block)
        return lines.joined(separator: "\n")
    }

    /// Whether a line is a YAML entry rather than blank or a comment.
    private static func deepseekIsContent(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return !line.isEmpty && !line.hasPrefix("#")
    }

    private static func deepseekJSON(_ values: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: values, options: .withoutEscapingSlashes)) ?? Data(), as: UTF8.self)
    }

    private static func status(command: String?, args: [String]?, script: String) -> ConnectorStatus {
        let args = args ?? []
        if args.contains(script) { return .connected }
        return .elsewhere(([command ?? ""] + args).filter { !$0.isEmpty }.joined(separator: " "))
    }
}
