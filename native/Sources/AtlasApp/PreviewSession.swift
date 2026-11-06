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

    func start(root: URL, runtime: WorkspaceLocation?) {
        guard process == nil else { return }
        phase = .starting
        stopping = false
        buffer = ""
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
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.buffer += text
                if self.phase == .starting, !self.stopping,
                   self.buffer.split(separator: "\n").contains("UI_ATLAS_READY") { self.phase = .ready }
                if self.buffer.count > 24000 { self.buffer = String(self.buffer.suffix(12000)) }
            }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.generation = UUID()
                self.output?.fileHandleForReading.readabilityHandler = nil
                if !self.stopping {
                    let detail = self.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.phase = .failed(detail.isEmpty ? "案例服务已退出（\(terminated.terminationStatus)）。请确认 Node.js、pnpm 和依赖已安装。" : detail)
                }
                self.process = nil
                self.input = nil
                self.output = nil
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
