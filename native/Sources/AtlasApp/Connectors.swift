import AtlasCore
import Foundation
import SwiftUI

struct CommandResult: Sendable {
    var exitCode: Int32
    var output: Data
    var error: String
}

/// MCP 连接器：检测 ui-atlas MCP server 是否已注册到 Claude Code / Codex 的用户级配置，并用它们的 CLI 连接或断开。
@MainActor
final class ConnectorsModel: ObservableObject {
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]) async -> CommandResult

    struct Entry: Equatable {
        /// nil 表示尚未检测完成。
        var status: ConnectorStatus?
        var busy = false
        var error: String?
    }

    @Published private(set) var entries: [AgentConnector: Entry] = Dictionary(uniqueKeysWithValues: AgentConnector.allCases.map { ($0, Entry()) })

    /// 本检出目录的 `scripts/mcp-server.mjs`；找不到源码目录时为 nil。
    let script: String?
    private let environment: [String: String]
    private let claudeConfig: URL
    private let isExecutable: (String) -> Bool
    private let run: Runner

    init(root: URL?, runtime: WorkspaceLocation?, inherited: [String: String] = ProcessInfo.processInfo.environment,
         claudeConfig: URL? = nil,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         run: @escaping Runner = ConnectorsModel.runProcess) {
        script = root?.appendingPathComponent("scripts/mcp-server.mjs").path
        var environment = inherited
        // 从 Finder 打开时 PATH 很短；补上构建时记录的 PATH，claude 等 Node CLI 才找得到 node。
        environment["PATH"] = [runtime?.path, inherited["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        self.environment = environment
        // claude CLI 在设置了 CLAUDE_CONFIG_DIR 时把用户级配置写在该目录下。
        self.claudeConfig = claudeConfig ?? URL(fileURLWithPath: inherited["CLAUDE_CONFIG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(".claude.json")
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
        await perform(connector, connector.addArguments(script: script), failure: L("Connection failed"))
    }

    func disconnect(_ connector: AgentConnector) async {
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
            // 未注册时 codex 报 “No MCP server named”；其他失败（如配置文件损坏）要显示出来，而不是只显示未连接。
            if result.exitCode != 0, !result.error.contains("No MCP server named"), entries[connector]?.error == nil {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                let failure = L("Could not check the connection status")
                entries[connector]?.error = detail.isEmpty ? L("%1$@ (%2$d)", failure, result.exitCode) : L("%1$@: %2$@", failure, detail)
            }
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
                // 先在后台读完 stderr，避免任一管道写满时子进程阻塞。
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

/// “MCP 连接器”窗口：每个 Agent 一行，显示连接状态与连接 / 断开连接按钮。
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
