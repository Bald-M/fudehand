import AppKit
import Combine
import Foundation

/// 持有 `native-preview.mjs` 启动器进程，按需请求各作品的开发服务。
/// 协议见该脚本：stdin 写 `start <id>`，stdout 读 `UI_ATLAS_LISTENING` / `UI_ATLAS_READY <id>` /
/// `UI_ATLAS_FAILED <id> <JSON>`；stderr 是日志，用于失败说明。
@MainActor
final class PreviewSession: ObservableObject {
    enum Phase: Equatable {
        case stopped, starting, ready, failed(String)
    }

    /// 启动器本身的状态；`.ready` 表示它已在等待作品请求。
    @Published private(set) var phase: Phase = .stopped
    /// 已请求过的案例服务状态。
    @Published private(set) var services: [String: Phase] = [:]
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var lines = ""
    private var logs = ""
    private var generation = UUID()
    private var stopping = false
    private var exitStatus: Int32?
    private var logsClosed = false

    /// 某个作品的状态：启动器失败或未运行时，作品随之失败或停止。
    func phase(for id: String?) -> Phase {
        switch phase {
        case .failed, .stopped: return phase
        case .starting, .ready: return id.flatMap { services[$0] } ?? .stopped
        }
    }

    /// 启动尚未运行或已失败的案例服务；已在启动或已就绪时不重复请求。
    func request(_ id: String) {
        guard process != nil else { return }
        switch services[id] {
        case .starting, .ready: return
        default: break
        }
        services[id] = .starting
        try? input?.fileHandleForWriting.write(contentsOf: Data("start \(id)\n".utf8))
    }

    func start(root: URL, runtime: WorkspaceLocation?) {
        guard process == nil else { return }
        phase = .starting
        services = [:]
        stopping = false
        lines = ""
        logs = ""
        exitStatus = nil
        logsClosed = false
        let token = UUID()
        generation = token
        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [runtime?.path, environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"].compactMap { $0 }.joined(separator: ":")
        if let node = runtime?.node, FileManager.default.isExecutableFile(atPath: node) {
            child.executableURL = URL(fileURLWithPath: node)
            child.arguments = [root.appendingPathComponent("scripts/native-preview.mjs").path, "--root", root.path]
        } else {
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.arguments = ["node", root.appendingPathComponent("scripts/native-preview.mjs").path, "--root", root.path]
        }
        child.currentDirectoryURL = root
        child.environment = environment
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        // 启动器退出后再写入请求，不能让 App 收到 SIGPIPE。
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // The main queue keeps output chunks in order, ending with EOF (an empty chunk).
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data, token: token) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.log(data, token: token) }
            }
        }
        child.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(status, token: token) }
            }
        }
        do {
            try child.run()
            stdinPipe.fileHandleForReading.closeFile()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            process = child
            input = stdinPipe
            output = stdoutPipe
            errors = stderrPipe
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            phase = .failed("无法启动案例服务：\(error.localizedDescription)\n请在仓库执行 pnpm install 后重新构建 App。")
        }
    }

    private func receive(_ data: Data, token: UUID) {
        guard generation == token, !stopping else { return }
        lines += String(decoding: data, as: UTF8.self)
        while let end = lines.firstIndex(of: "\n") {
            let line = String(lines[..<end])
            lines.removeSubrange(...end)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "UI_ATLAS_LISTENING":
            if phase == .starting { phase = .ready }
        case "UI_ATLAS_READY" where parts.count >= 2:
            services[parts[1]] = .ready
        case "UI_ATLAS_FAILED" where parts.count >= 2:
            let message = parts.count == 3 ? (try? JSONDecoder().decode(String.self, from: Data(parts[2].utf8))) ?? parts[2] : "案例服务未能启动"
            let detail = recentLogs()
            services[parts[1]] = .failed(detail.isEmpty ? message : "\(message)\n\n最近的日志：\n\(detail)")
        default:
            break
        }
    }

    private func log(_ data: Data, token: UUID) {
        guard generation == token else { return }
        if data.isEmpty {
            logsClosed = true
            finish(token: token)
            return
        }
        logs += String(decoding: data, as: UTF8.self)
        if logs.count > 24000 { logs = String(logs.suffix(12000)) }
    }

    private func recentLogs() -> String {
        logs.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exit can be reported before the last output arrives; wait briefly for EOF so the
    /// failure message includes the launcher's final error. Lingering grandchildren can
    /// hold the pipe open, so the wait is bounded.
    private func exited(_ status: Int32, token: UUID) {
        guard generation == token else { return }
        exitStatus = status
        if logsClosed { finish(token: token); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.finish(token: token) }
        }
    }

    private func finish(token: UUID) {
        guard generation == token, let status = exitStatus else { return }
        generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        if !stopping {
            let detail = logs.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed(detail.isEmpty ? "案例服务已退出（\(status)）。请确认 Node.js、pnpm 和依赖已安装。" : detail)
        }
        process = nil
        input = nil
        output = nil
        errors = nil
    }

    func stop() async {
        stopping = true
        generation = UUID()
        input?.fileHandleForWriting.closeFile()
        // EOF lets the launcher finish cleaning up its own process groups.
        if let child = process {
            for _ in 0..<100 {
                if !child.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if child.isRunning {
                child.terminate()
                for _ in 0..<50 {
                    if !child.isRunning { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        errors = nil
        phase = .stopped
        services = [:]
    }
}

struct WorkspaceLocation: Decodable {
    let root: String
    let node: String?
    let path: String?
}
