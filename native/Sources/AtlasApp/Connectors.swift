import AtlasCore
import Foundation
import SwiftUI

struct CommandResult: Sendable {
    var exitCode: Int32
    var output: Data
    var error: String
}

/// MCP connectors: detects whether the ui-atlas MCP server is registered in the user-level configuration of Claude Code / Codex / DeepSeek Harness, and connects or disconnects it (through the CLI for Claude Code and Codex, by editing the home patch file for DeepSeek Harness).
@MainActor
final class ConnectorsModel: ObservableObject {
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]) async -> CommandResult

    struct Entry: Equatable {
        /// nil means detection has not finished yet.
        var status: ConnectorStatus?
        var busy = false
        var error: String?
    }

    @Published private(set) var entries: [AgentConnector: Entry] = Dictionary(uniqueKeysWithValues: AgentConnector.allCases.map { ($0, Entry()) })

    /// This checkout's `scripts/mcp-server.mjs`; nil when the source directory cannot be found.
    let script: String?
    private let environment: [String: String]
    private let claudeConfig: URL
    /// DeepSeek Harness's home patch file, and the Node the entry written there starts the MCP server with.
    private let deepseekPatch: URL
    private let node: String
    private let isExecutable: (String) -> Bool
    private let run: Runner

    init(root: URL?, runtime: WorkspaceLocation?, inherited: [String: String] = ProcessInfo.processInfo.environment,
         claudeConfig: URL? = nil,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         run: @escaping Runner = ConnectorsModel.runProcess) {
        script = root?.appendingPathComponent("scripts/mcp-server.mjs").path
        var environment = inherited
        // PATH is very short when opened from Finder; add the PATH recorded at build time so Node CLIs such as claude can find node.
        environment["PATH"] = [runtime?.path, inherited["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        self.environment = environment
        // When CLAUDE_CONFIG_DIR is set, the claude CLI writes the user-level configuration under that directory.
        self.claudeConfig = claudeConfig ?? URL(fileURLWithPath: inherited["CLAUDE_CONFIG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(".claude.json")
        // DeepSeek Harness starts MCP servers with the PATH it was launched with, which from Finder does not include Node: write the absolute path.
        node = runtime?.node ?? "node"
        deepseekPatch = URL(fileURLWithPath: inherited["DSH_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path)
            .appendingPathComponent("cordis.patch.yml")
        self.isExecutable = isExecutable
        self.run = run
    }

    func refresh() async {
        for connector in AgentConnector.allCases where entries[connector]?.busy == false {
            entries[connector]?.error = nil
            await refresh(connector)
        }
    }

    func connect(_ connector: AgentConnector) async {
        guard let script else { entries[connector]?.error = L("Cannot find the ui-atlas source directory, so it cannot connect"); return }
        if connector == .deepseek {
            let node = node
            await editDeepseekPatch(failure: L("Connection failed")) { AgentConnector.deepseekConnecting(patch: $0, node: node, script: script) }
            return
        }
        await perform(connector, connector.addArguments(script: script), failure: L("Connection failed"))
    }

    func disconnect(_ connector: AgentConnector) async {
        if connector == .deepseek {
            await editDeepseekPatch(failure: L("Disconnect failed")) { $0.flatMap(AgentConnector.deepseekDisconnecting) }
            return
        }
        await perform(connector, connector.removeArguments, failure: L("Disconnect failed"))
    }

    private func perform(_ connector: AgentConnector, _ arguments: [String], failure: String) async {
        guard entries[connector]?.busy == false, let executable = locate(connector) else { return }
        entries[connector]?.busy = true
        entries[connector]?.error = nil
        let result = await run(executable, arguments, environment)
        if result.exitCode != 0 {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            entries[connector]?.error = detail.isEmpty ? L("%1$@ (%2$d)", failure, result.exitCode) : L("%1$@: %2$@", failure, detail)
        }
        await refresh(connector)
        entries[connector]?.busy = false
    }

    /// Rewrites DeepSeek Harness's home patch file with `edit` (nil in: no file; nil out: delete the file), keeping the file's permissions.
    private func editDeepseekPatch(failure: String, _ edit: @escaping @Sendable (String?) -> String?) async {
        let connector = AgentConnector.deepseek
        guard entries[connector]?.busy == false, locate(connector) != nil else { return }
        entries[connector]?.busy = true
        entries[connector]?.error = nil
        // Edit the file a symbolic link points at rather than replacing the link.
        let file = deepseekPatch.resolvingSymlinksInPath()
        let error: String? = await Task.detached {
            let files = FileManager.default
            do {
                let old = files.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : nil
                let permissions = (try? files.attributesOfItem(atPath: file.path))?[.posixPermissions] ?? 0o600
                guard let new = edit(old) else {
                    if old != nil { try files.removeItem(at: file) }
                    return nil
                }
                guard new != old else { return nil }
                try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(new.utf8).write(to: file, options: .atomic)
                try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
                return nil
            } catch { return error.localizedDescription }
        }.value
        if let error { entries[connector]?.error = L("%1$@: %2$@", failure, error) }
        await refresh(connector)
        entries[connector]?.busy = false
    }

    private func refresh(_ connector: AgentConnector) async {
        guard let executable = locate(connector) else { entries[connector]?.status = .unavailable; return }
        let script = script ?? ""
        switch connector {
        case .claude:
            let config = claudeConfig
            let data = await Task.detached { try? Data(contentsOf: config) }.value
            entries[connector]?.status = AgentConnector.claudeStatus(config: data, script: script)
        case .codex:
            let result = await run(executable, connector.statusArguments ?? [], environment)
            entries[connector]?.status = AgentConnector.codexStatus(output: result.output, exitCode: result.exitCode, script: script)
            // When not registered, codex reports "No MCP server named"; other failures (such as a corrupted configuration file) must be shown rather than only showing not connected.
            if result.exitCode != 0, !result.error.contains("No MCP server named"), entries[connector]?.error == nil {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                let failure = L("Could not check the connection status")
                entries[connector]?.error = detail.isEmpty ? L("%1$@ (%2$d)", failure, result.exitCode) : L("%1$@: %2$@", failure, detail)
            }
        case .deepseek:
            let file = deepseekPatch
            let patch = await Task.detached { try? String(contentsOf: file, encoding: .utf8) }.value
            entries[connector]?.status = AgentConnector.deepseekStatus(patch: patch, script: script)
        }
    }

    private func locate(_ connector: AgentConnector) -> String? {
        connector.locate(path: environment["PATH"] ?? "", isExecutable: isExecutable)
    }

    nonisolated static func runProcess(_ executable: String, _ arguments: [String], _ environment: [String: String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: executable)
                child.arguments = arguments
                child.environment = environment
                child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let output = Pipe(), error = Pipe()
                child.standardOutput = output
                child.standardError = error
                child.standardInput = FileHandle.nullDevice
                do { try child.run() } catch {
                    continuation.resume(returning: CommandResult(exitCode: -1, output: Data(), error: error.localizedDescription))
                    return
                }
                // Read all of stderr in the background first, so the child process does not block when either pipe fills up.
                var errorData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errorData = error.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                child.waitUntilExit()
                continuation.resume(returning: CommandResult(exitCode: child.terminationStatus, output: data,
                                                             error: String(decoding: errorData, as: UTF8.self)))
            }
        }
    }
}

/// The "MCP Connectors" window: one row per Agent, showing the connection status and the Connect / Disconnect button.
struct ConnectorsView: View {
    @ObservedObject var model: ConnectorsModel
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Connect ui-atlas’s design tools to external Agents. Once connected, an Agent can read and edit the design document open in the App."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(AgentConnector.allCases.enumerated()), id: \.element) { index, connector in
                    if index > 0 { Divider() }
                    ConnectorRow(connector: connector, entry: model.entries[connector] ?? .init(), model: model)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Text(L("This changes each Agent’s user-level configuration and applies to new sessions.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Refresh")) { Task { await model.refresh() } }
            }
        }
        .padding(20)
        .frame(width: 520)
        // The scene's title is not refreshed while the window is open; this one is.
        .navigationTitle(L("MCP Connectors"))
        .task { await model.refresh() }
    }
}

private struct ConnectorRow: View {
    let connector: AgentConnector
    let entry: ConnectorsModel.Entry
    let model: ConnectorsModel
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(connector.title).font(.headline)
                Text(statusText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = entry.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if entry.busy || entry.status == nil {
                ProgressView().controlSize(.small).frame(height: 22)
            } else if let action {
                Button(action.title) { Task { await action.run() } }
                    .disabled(entry.status == .disconnected && model.script == nil)
            }
        }
        .padding(12)
    }

    private var statusText: String {
        switch entry.status {
        case nil: L("Checking…")
        case .unavailable: L("The %1$@ command was not found. Install %2$@ first.", connector.executable, connector.title)
        case .disconnected: L("Not connected")
        case .connected: L("Connected")
        case .elsewhere(let command): L("Registered to another directory: %@. Disconnect to reconnect it to this one.", command)
        }
    }

    private var color: Color {
        switch entry.status {
        case .connected: .green
        case .elsewhere: .orange
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var action: (title: String, run: () async -> Void)? {
        switch entry.status {
        case .disconnected: (L("Connect"), { await model.connect(connector) })
        case .connected, .elsewhere: (L("Disconnect"), { await model.disconnect(connector) })
        default: nil
        }
    }
}
