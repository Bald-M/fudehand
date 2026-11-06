import AppKit
import Combine
import Foundation

@MainActor
final class PreviewSession: ObservableObject {
    enum Phase: Equatable {
        case stopped, starting, ready, failed(String)
    }

    @Published private(set) var phase: Phase = .stopped
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = ""
    private var generation = UUID()
    private var stopping = false
    private var exitStatus: Int32?
    private var outputClosed = false

    func start(root: URL, runtime: WorkspaceLocation?) {
        guard process == nil else { return }
        phase = .starting
        stopping = false
        buffer = ""
        exitStatus = nil
        outputClosed = false
        let token = UUID()
        generation = token
        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
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
        child.standardError = stdoutPipe
        // The main queue keeps output chunks in order, ending with EOF (an empty chunk).
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data, token: token) }
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
            process = child
            input = stdinPipe
            output = stdoutPipe
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            phase = .failed("无法启动案例服务：\(error.localizedDescription)\n请在仓库执行 pnpm install 后重新构建 App。")
        }
    }

    private func receive(_ data: Data, token: UUID) {
        guard generation == token else { return }
        if data.isEmpty {
            outputClosed = true
            finish(token: token)
            return
        }
        buffer += String(decoding: data, as: UTF8.self)
        if phase == .starting, !stopping, buffer.split(separator: "\n").contains("UI_ATLAS_READY") { phase = .ready }
        if buffer.count > 24000 { buffer = String(buffer.suffix(12000)) }
    }

    /// Exit can be reported before the last output arrives; wait briefly for EOF so the
    /// failure message includes the launcher's final error. Lingering grandchildren can
    /// hold the pipe open, so the wait is bounded.
    private func exited(_ status: Int32, token: UUID) {
        guard generation == token else { return }
        exitStatus = status
        if outputClosed { finish(token: token); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.finish(token: token) }
        }
    }

    private func finish(token: UUID) {
        guard generation == token, let status = exitStatus else { return }
        generation = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        if !stopping {
            let detail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed(detail.isEmpty ? "案例服务已退出（\(status)）。请确认 Node.js、pnpm 和依赖已安装。" : detail)
        }
        process = nil
        input = nil
        output = nil
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
        process = nil
        input = nil
        output = nil
        phase = .stopped
    }
}

struct WorkspaceLocation: Decodable {
    let root: String
    let node: String?
    let path: String?
}
