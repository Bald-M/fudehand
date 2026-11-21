import FudehandCore
import Foundation
import SwiftUI

struct CommandResult: Sendable {
    var exitCode: Int32
    var output: Data
    var error: String
}

/// What a connect or disconnect did, for the Agent tool: the command it ran or the file it changed, and why it failed, in English.
struct ConnectorOutcome {
    var command: [String]?
    var file: String?
    var error: String?
}

/// MCP connectors: detects whether the Fudehand MCP server is registered in the user-level configuration of Claude Code / Codex / DeepSeek Harness, and connects or disconnects it (through the CLI for Claude Code and Codex, by editing the home patch file for DeepSeek Harness).
@MainActor
final class ConnectorsModel: ObservableObject {
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]) async -> CommandResult

    struct Entry: Equatable {
        /// nil means detection has not finished yet.
        var status: ConnectorStatus?
        var busy = false
        var error: String?
        /// `error` in English, for the Agent tools.
        var englishError: String?
    }

    @Published private(set) var entries: [AgentConnector: Entry] = Dictionary(uniqueKeysWithValues: AgentConnector.allCases.map { ($0, Entry()) })
    /// The Node.js the MCP server runs on; nil until the first refresh has looked for it.
    @Published private(set) var node: NodeStatus?

    /// The App's `scripts/mcp-server.mjs` (in the source checkout, or the installed copy of the bundled tools); nil when neither is found.
    let script: String?
    private var environment: [String: String]
    private let claudeConfig: URL
    /// DeepSeek Harness's home patch file.
    private let deepseekPatch: URL
    /// The Node recorded at build time (source builds only); tried first.
    private let recordedNode: String?
    private let searchPath: (_ login: String?) -> String
    /// Reads the login shell's PATH once; every refresh waits for the same read.
    private var loginPathRead: Task<Void, Never>?
    private let loginPath: @Sendable () async -> String?
    private let isExecutable: (String) -> Bool
    private let run: Runner

    init(root: URL?, runtime: WorkspaceLocation?, inherited: [String: String] = ProcessInfo.processInfo.environment,
         home: String = NSHomeDirectory(), claudeConfig: URL? = nil,
         isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
         loginPath: @escaping @Sendable () async -> String? = ConnectorsModel.readLoginShellPath,
         run: @escaping Runner = ConnectorsModel.runProcess) {
        script = root?.appendingPathComponent("scripts/mcp-server.mjs").path
        // PATH is very short when opened from Finder: search the PATH recorded at build time, the login shell's PATH, and the usual install
        // locations, for the Agent CLIs, for Node, and for Node CLIs such as claude that look for node on the PATH.
        let nvm = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.nvm/versions/node")) ?? []
        searchPath = { ToolSearchPath.compose(recorded: runtime?.path, login: $0, inherited: inherited["PATH"], home: home, nvmVersions: nvm) }
        environment = inherited
        environment["PATH"] = searchPath(nil)
        // When CLAUDE_CONFIG_DIR is set, the claude CLI writes the user-level configuration under that directory.
        self.claudeConfig = claudeConfig ?? URL(fileURLWithPath: inherited["CLAUDE_CONFIG_DIR"] ?? home).appendingPathComponent(".claude.json")
        recordedNode = runtime?.node
        deepseekPatch = URL(fileURLWithPath: inherited["DSH_HOME"] ?? home + "/.dsh").appendingPathComponent("cordis.patch.yml")
        self.loginPath = loginPath
        self.isExecutable = isExecutable
        self.run = run
    }

    func refresh() async {
        if loginPathRead == nil {
            let read = loginPath
            loginPathRead = Task { if let login = await read() { environment["PATH"] = searchPath(login) } }
        }
        await loginPathRead?.value
        await findNode()
        for connector in AgentConnector.allCases where entries[connector]?.busy == false {
            fail(connector, nil)
            await refresh(connector)
        }
    }

    @discardableResult
    func connect(_ connector: AgentConnector) async -> ConnectorOutcome {
        guard let script else {
            fail(connector, (L("Cannot find the Fudehand source directory, so it cannot connect"), "Cannot find the Fudehand source directory, so it cannot connect"))
            return ConnectorOutcome(error: entries[connector]?.englishError)
        }
        if node == nil { await findNode() }
        // Registered with the absolute path: an Agent opened from Finder or the Dock may not have Node on its PATH.
        guard let node = node?.path else {
            let message = nodeProblem ?? (L("Node.js was not found."), "Node.js was not found.")
            fail(connector, message)
            return ConnectorOutcome(error: message.english)
        }
        if connector == .deepseek {
            return await editDeepseekPatch(failure: (L("Connection failed"), "Connection failed")) { AgentConnector.deepseekConnecting(patch: $0, node: node, script: script) }
        }
        // `mcp add` refuses a name that is already registered: an old registration is removed first.
        var commands = [connector.addArguments(node: node, script: script)]
        if case .elsewhere = entries[connector]?.status { commands.insert(connector.removeArguments, at: 0) }
        return await perform(connector, commands, failure: (L("Connection failed"), "Connection failed"))
    }

    /// Why the MCP server cannot run, localized for the window and in English for the Agent tools; nil when a supported Node was found.
    var nodeProblem: (local: String, english: String)? {
        switch node {
        case .missing:
            (L("Fudehand’s MCP server needs Node.js %@ or later, which was not found on this Mac. Install it from nodejs.org or with Homebrew (brew install node), then click Refresh.", NodeRuntime.minimumText),
             "Fudehand's MCP server needs Node.js \(NodeRuntime.minimumText) or later, which was not found on this Mac. Install it from nodejs.org or with Homebrew (brew install node), then refresh.")
        case .tooOld(let path, let version):
            (L("Fudehand’s MCP server needs Node.js %1$@ or later, but %2$@ is version %3$@. Update Node.js, then click Refresh.", NodeRuntime.minimumText, path, version),
             "Fudehand's MCP server needs Node.js \(NodeRuntime.minimumText) or later, but \(path) is version \(version). Update Node.js, then refresh.")
        case .found, nil: nil
        }
    }

    /// Looks for a supported Node on the search path, preferring the one recorded at build time.
    private func findNode() async {
        var seen = Set<String>()
        let candidates = ([recordedNode].compactMap { $0 } + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/node" })
            .filter { seen.insert($0).inserted && isExecutable($0) }
        var results: [(path: String, output: String?)] = []
        for candidate in candidates {
            let result = await run(candidate, ["--version"], environment)
            results.append((candidate, result.exitCode == 0 ? String(decoding: result.output, as: UTF8.self) : nil))
            if case .found = NodeRuntime.pick(results) { break }
        }
        node = NodeRuntime.pick(results)
    }

    @discardableResult
    func disconnect(_ connector: AgentConnector) async -> ConnectorOutcome {
        if connector == .deepseek {
            return await editDeepseekPatch(failure: (L("Disconnect failed"), "Disconnect failed")) { $0.flatMap(AgentConnector.deepseekDisconnecting) }
        }
        return await perform(connector, [connector.removeArguments], failure: (L("Disconnect failed"), "Disconnect failed"))
    }

    /// The connector's CLI, or why the connector cannot be changed now, in English.
    private func available(_ connector: AgentConnector) -> Result<String, ConnectorUnavailable> {
        if entries[connector]?.busy != false { return .failure(.init(reason: "\(connector.title) is already being changed; try again when it finishes")) }
        guard let executable = locate(connector) else { return .failure(.init(reason: "The \(connector.executable) command was not found; install \(connector.title) first")) }
        return .success(executable)
    }

    private struct ConnectorUnavailable: Error { let reason: String }

    /// Runs `commands` in order, stopping at the first that fails; the outcome names the last one run.
    /// `failure` is the message's start, localized for the window and in English for the Agent tool.
    private func perform(_ connector: AgentConnector, _ commands: [[String]], failure: (local: String, english: String)) async -> ConnectorOutcome {
        let executable: String
        switch available(connector) {
        case .success(let found): executable = found
        case .failure(let unavailable): return ConnectorOutcome(error: unavailable.reason)
        }
        entries[connector]?.busy = true
        fail(connector, nil)
        var outcome = ConnectorOutcome()
        for arguments in commands {
            let result = await run(executable, arguments, environment)
            outcome.command = [executable] + arguments
            guard result.exitCode != 0 else { continue }
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            fail(connector, detail.isEmpty ? (L("%1$@ (%2$d)", failure.local, result.exitCode), "\(failure.english) (\(result.exitCode))")
                                           : (L("%1$@: %2$@", failure.local, detail), "\(failure.english): \(detail)"))
            outcome.error = entries[connector]?.englishError
            break
        }
        await refresh(connector)
        entries[connector]?.busy = false
        return outcome
    }

    /// Rewrites DeepSeek Harness's home patch file with `edit` (nil in: no file; nil out: delete the file), keeping the file's permissions.
    private func editDeepseekPatch(failure: (local: String, english: String), _ edit: @escaping @Sendable (String?) -> String?) async -> ConnectorOutcome {
        let connector = AgentConnector.deepseek
        if case .failure(let unavailable) = available(connector) { return ConnectorOutcome(error: unavailable.reason) }
        entries[connector]?.busy = true
        fail(connector, nil)
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
        var outcome = ConnectorOutcome(file: file.path)
        if let error {
            fail(connector, (L("%1$@: %2$@", failure.local, error), "\(failure.english): \(error)"))
            outcome.error = entries[connector]?.englishError
        }
        await refresh(connector)
        entries[connector]?.busy = false
        return outcome
    }

    private func refresh(_ connector: AgentConnector) async {
        guard let executable = locate(connector) else { entries[connector]?.status = .unavailable; return }
        let script = script ?? ""
        let exists = isExecutable
        switch connector {
        case .claude:
            let config = claudeConfig
            let data = await Task.detached { try? Data(contentsOf: config) }.value
            entries[connector]?.status = AgentConnector.claudeStatus(config: data, script: script, commandExists: exists)
        case .codex:
            let result = await run(executable, connector.statusArguments ?? [], environment)
            entries[connector]?.status = AgentConnector.codexStatus(output: result.output, exitCode: result.exitCode, script: script, commandExists: exists)
            // When not registered, codex reports "No MCP server named"; other failures (such as a corrupted configuration file) must be shown rather than only showing not connected.
            if result.exitCode != 0, !result.error.contains("No MCP server named"), entries[connector]?.error == nil {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                let failure = L("Could not check the connection status"), english = "Could not check the connection status"
                fail(connector, detail.isEmpty ? (L("%1$@ (%2$d)", failure, result.exitCode), "\(english) (\(result.exitCode))")
                                               : (L("%1$@: %2$@", failure, detail), "\(english): \(detail)"))
            }
        case .deepseek:
            let file = deepseekPatch
            let patch = await Task.detached { try? String(contentsOf: file, encoding: .utf8) }.value
            entries[connector]?.status = AgentConnector.deepseekStatus(patch: patch, script: script, commandExists: exists)
        }
    }

    /// Records the connector's error, localized for the window and in English for the Agent tools; nil clears it.
    private func fail(_ connector: AgentConnector, _ message: (local: String, english: String)?) {
        entries[connector]?.error = message?.local
        entries[connector]?.englishError = message?.english
    }

    private func locate(_ connector: AgentConnector) -> String? {
        connector.locate(path: environment["PATH"] ?? "", isExecutable: isExecutable)
    }

    /// The login shell's PATH, which holds what the user's profile adds (Homebrew, a custom npm prefix); nil when it does not answer in time.
    /// Output is collected as it arrives and not read to the end: a command the profile started may outlive the shell and keep the pipe open.
    nonisolated static func readLoginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var continuation: CheckedContinuation<String?, Never>?
            func finish() {
                lock.lock(); let continuation = continuation; self.continuation = nil; let data = data; lock.unlock()
                continuation?.resume(returning: ToolSearchPath.loginPath(fromShellOutput: String(decoding: data, as: UTF8.self)))
            }
        }
        let collected = Collected()
        return await withCheckedContinuation { continuation in
            collected.continuation = continuation
            let child = Process()
            child.executableURL = URL(fileURLWithPath: shell)
            child.arguments = ToolSearchPath.shellArguments
            child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let output = Pipe()
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            child.standardInput = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                collected.lock.lock(); collected.data.append(chunk); collected.lock.unlock()
                if chunk.isEmpty { handle.readabilityHandler = nil }
            }
            // The marker line is printed last, so the shell exiting means it is there (or never will be); give the pipe a moment to drain.
            child.terminationHandler = { _ in DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { collected.finish() } }
            do { try child.run() } catch { collected.finish(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if child.isRunning { child.terminate() }
                collected.finish()
            }
        }
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
            Text(L("Connect Fudehand’s design tools to external Agents. Once connected, an Agent can read and edit the design document open in the App."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.script == nil {
                Label(L("Cannot find the Fudehand source directory, so it cannot connect"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).symbolRenderingMode(.multicolor).fixedSize(horizontal: false, vertical: true)
            } else if let problem = model.nodeProblem {
                Label(problem.local, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.primary).symbolRenderingMode(.multicolor)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
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
            icon
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
            } else {
                HStack(spacing: 6) {
                    ForEach(actions, id: \.title) { action in
                        Button(action.title) { Task { await action.run() } }
                            .disabled(action.connects && (model.script == nil || model.node?.path == nil))
                    }
                }
            }
        }
        .padding(12)
    }

    /// The Agent's icon with the status dot as a badge on its corner; dimmed and desaturated when the CLI is not installed. The name
    /// beside it says the same, so VoiceOver skips it.
    private var icon: some View {
        Group {
            if let image = ConnectorIcon.image(for: connector) { Image(nsImage: image).resizable().interpolation(.high) } else { Color.clear }
        }
        .frame(width: 28, height: 28)
        .saturation(entry.status == .unavailable ? 0 : 1)
        .opacity(entry.status == .unavailable ? 0.4 : 1)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(color).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5).padding(-1.5))
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }

    private var statusText: String {
        switch entry.status {
        case nil: L("Checking…")
        case .unavailable: L("The %1$@ command was not found. Install %2$@ first.", connector.executable, connector.title)
        case .disconnected: L("Not connected")
        case .connected: L("Connected")
        case .elsewhere(let command): L("Registered to another location: %@. Update points it at this App.", command)
        }
    }

    private var color: Color {
        switch entry.status {
        case .connected: .green
        case .elsewhere: .orange
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// `connects`: the action registers this App's MCP server, so it needs the server and Node.
    private var actions: [(title: String, connects: Bool, run: () async -> Void)] {
        let connect: () async -> Void = { await model.connect(connector) }, disconnect: () async -> Void = { await model.disconnect(connector) }
        return switch entry.status {
        case .disconnected: [(L("Connect"), true, connect)]
        case .connected: [(L("Disconnect"), false, disconnect)]
        case .elsewhere: [(L("Update"), true, connect), (L("Disconnect"), false, disconnect)]
        default: []
        }
    }
}
