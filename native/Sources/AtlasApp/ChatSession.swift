import AtlasCore
import Combine
import Foundation

/// 对话面板的模型设置；不含 API key（key 在钥匙串）。
struct ChatSettings: Equatable {
    static let providers: [(id: String, title: String)] = [("deepseek", "DeepSeek"), ("anthropic", "Anthropic Claude"), ("openai", "OpenAI")]

    var provider: String
    /// 留空时由 harness 使用该提供方的默认模型和官方地址。
    var model: String
    var baseUrl: String

    var providerTitle: String { Self.providers.first { $0.id == provider }?.title ?? provider }
}

/// 管理 App 内的 Agent harness（scripts/agent-chat.mjs）子进程：按需启动，经 stdin/stdout 交换 JSON 行。
/// 设置或 key 变化后结束当前进程，下一条消息用新配置重新启动。
@MainActor
final class ChatSession: ObservableObject {
    struct Launch {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    @Published private(set) var transcript = ChatTranscript()
    @Published var settings: ChatSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.set(settings.provider, forKey: "agent.provider")
            defaults.set(settings.model, forKey: "agent.\(settings.provider).model")
            defaults.set(settings.baseUrl, forKey: "agent.\(settings.provider).baseUrl")
            hasKey = defaults.bool(forKey: "agent.\(settings.provider).hasKey")
            restart()
        }
    }
    /// 是否已在钥匙串保存当前提供方的 key。只记录标记，避免启动时读取钥匙串触发授权提示。
    @Published private(set) var hasKey = false

    private let defaults: UserDefaults
    private let readKey: (String) -> String?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    /// harness 的最后几行错误输出，进程意外退出时显示。
    private var errorOutput = ""
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, readKey: @escaping (String) -> String? = Keychain.read) {
        self.defaults = defaults
        self.readKey = readKey
        let provider = defaults.string(forKey: "agent.provider").flatMap { id in ChatSettings.providers.contains { $0.id == id } ? id : nil } ?? "deepseek"
        settings = Self.stored(provider, defaults)
        hasKey = defaults.bool(forKey: "agent.\(provider).hasKey")
    }

    nonisolated static func stored(_ provider: String, _ defaults: UserDefaults) -> ChatSettings {
        ChatSettings(provider: provider, model: defaults.string(forKey: "agent.\(provider).model") ?? "",
                     baseUrl: defaults.string(forKey: "agent.\(provider).baseUrl") ?? "")
    }

    func savedKey(for provider: String) -> Bool { defaults.bool(forKey: "agent.\(provider).hasKey") }

    /// 钥匙串中某个提供方的 key 保存或删除后调用；只有当前提供方的变化才需要重启对话程序。
    func keyUpdated(provider: String, saved: Bool) {
        defaults.set(saved, forKey: "agent.\(provider).hasKey")
        guard provider == settings.provider else { return }
        hasKey = saved
        restart()
    }

    nonisolated static func launch(root: URL, runtime: WorkspaceLocation?, settings: ChatSettings, apiKey: String?, environment inherited: [String: String]) -> Launch {
        var environment = inherited.filter { !$0.key.hasPrefix("UI_ATLAS_") || $0.key == "UI_ATLAS_CONTROL_SOCKET" }
        environment["PATH"] = [runtime?.path, inherited["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"].compactMap { $0 }.joined(separator: ":")
        environment["UI_ATLAS_PROVIDER"] = settings.provider
        if !settings.model.isEmpty { environment["UI_ATLAS_MODEL"] = settings.model }
        if !settings.baseUrl.isEmpty { environment["UI_ATLAS_BASE_URL"] = settings.baseUrl }
        if let apiKey, !apiKey.isEmpty { environment["UI_ATLAS_API_KEY"] = apiKey }
        let script = root.appendingPathComponent("scripts/agent-chat.mjs").path
        if let node = runtime?.node {
            return Launch(executable: URL(fileURLWithPath: node), arguments: [script, "--root", root.path], environment: environment)
        }
        return Launch(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", script, "--root", root.path], environment: environment)
    }

    func send(_ text: String, root: URL?, runtime: WorkspaceLocation?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !transcript.busy else { return }
        transcript.send(trimmed)
        guard let root else { transcript.fail("尚未打开项目目录"); return }
        if process == nil {
            do { try start(root: root, runtime: runtime) }
            catch { transcript.fail("无法启动对话程序：\(error.localizedDescription)"); return }
        }
        write(["type": "user", "text": trimmed])
    }

    func stopReply() { write(["type": "stop"]) }

    /// 回复进行中不清空，避免随后到达的结束事件写进新会话。
    func clear() {
        guard !transcript.busy else { return }
        write(["type": "clear"])
        transcript.clear()
    }

    func shutdown() async {
        terminate()
    }

    private func restart() {
        guard process != nil else { return }
        terminate()
        transcript.note("已切换模型设置，新的回复不包含之前的上下文。")
    }

    private func start(root: URL, runtime: WorkspaceLocation?) throws {
        let launch = Self.launch(root: root, runtime: runtime, settings: settings, apiKey: readKey(settings.provider),
                                 environment: ProcessInfo.processInfo.environment)
        let child = Process()
        child.executableURL = launch.executable
        child.arguments = launch.arguments
        child.environment = launch.environment
        child.currentDirectoryURL = root
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        // 进程已退出时写入 stdin 返回错误，而不是向 App 发送 SIGPIPE。
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let token = UUID()
        generation = token
        buffer = Data()
        errorOutput = ""
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveError(data, token: token) } }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data, token: token) } }
        }
        child.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status, token: token) } }
        }
        try child.run()
        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        process = child
        input = stdinPipe.fileHandleForWriting
    }

    private func write(_ message: [String: String]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        // 进程已退出时写入会失败；App 已忽略 SIGPIPE，失败由退出回调报告。
        try? input.write(contentsOf: data)
    }

    private func receive(_ data: Data, token: UUID) {
        guard generation == token else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            transcript.apply(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }

    private func receiveError(_ data: Data, token: UUID) {
        guard generation == token else { return }
        errorOutput = String((errorOutput + String(decoding: data, as: UTF8.self)).suffix(600))
    }

    private func exited(_ status: Int32, token: UUID) {
        guard generation == token else { return }
        generation = UUID()
        process = nil
        input = nil
        guard transcript.busy else { return }
        // harness 自己会去掉 key，这里不显示 stderr 之外的内容。
        let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.fail("对话程序意外退出（\(status)）。请确认已在项目目录执行 pnpm install。" + (detail.isEmpty ? "" : "\n\(detail)"))
    }

    private func terminate() {
        generation = UUID()
        // 关闭 stdin 后 harness 会中止当前请求并退出。
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
    }
}
