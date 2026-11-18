import AtlasCore
import Combine
import Foundation

/// The chat panel's model settings; excludes the API key (the key is in the Keychain).
struct ChatSettings: Equatable {
    static let providers: [(id: String, title: String)] = [("deepseek", "DeepSeek"), ("anthropic", "Anthropic Claude"), ("openai", "OpenAI")]

    var provider: String
    /// When left empty, the harness uses the provider's default model and official address.
    var model: String
    var baseUrl: String

    var providerTitle: String { Self.providers.first { $0.id == provider }?.title ?? provider }

    /// Keeps only the first and last 4 characters, to recognize the key in the UI; a key that is too short is masked entirely.
    static func maskedKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard trimmed.count >= 12 else { return "••••••••" }
        return "\(trimmed.prefix(4))••••••••\(trimmed.suffix(4))"
    }
}

/// The model IDs returned by the provider's model-list endpoint, and the default model the harness uses when the model is left empty.
struct ModelListing: Equatable {
    var models: [String]
    var defaultModel: String
}

struct ModelListError: Error, Equatable {
    let message: String
}

/// Manages the child process of the in-App Agent harness (scripts/agent-chat.mjs): started on demand, exchanging JSON lines over stdin/stdout.
/// After the settings or the key change, the current process is ended and the next message restarts it with the new configuration.
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
    /// Whether the current provider's key is saved in the Keychain. Only a flag is recorded, so launch does not read the Keychain and trigger an authorization prompt.
    @Published private(set) var hasKey = false

    private let defaults: UserDefaults
    private let readKey: (String) -> String?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    /// The last few lines of the harness's error output, shown when the process exits unexpectedly.
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

    /// The masked form of the saved key; the full key is only in the Keychain.
    func keyHint(for provider: String) -> String? { defaults.string(forKey: "agent.\(provider).keyHint") }

    /// Reads the key saved in the Keychain (may trigger an authorization prompt), and adds the masked hint for a key saved by an older version without one.
    func savedKeyValue(for provider: String) -> String? {
        guard savedKey(for: provider), let key = storedKey(for: provider) else { return nil }
        if keyHint(for: provider) == nil { defaults.set(ChatSettings.maskedKey(key), forKey: "agent.\(provider).keyHint") }
        return key
    }

    /// Reads the provider's key from the Keychain. When the flag says a key is saved but the Keychain has none (for example it was deleted
    /// outside the App), the flag is cleared so the panel asks for a key again instead of only showing the harness error.
    private func storedKey(for provider: String) -> String? {
        let key = readKey(provider)
        if key == nil, savedKey(for: provider) {
            defaults.set(false, forKey: "agent.\(provider).hasKey")
            defaults.removeObject(forKey: "agent.\(provider).keyHint")
            if provider == settings.provider { hasKey = false }
        }
        return key
    }

    /// Called after a provider's key is saved to or deleted from the Keychain; only a change to the current provider needs the chat program restarted.
    func keyUpdated(provider: String, saved: Bool, key: String? = nil) {
        defaults.set(saved, forKey: "agent.\(provider).hasKey")
        if !saved { defaults.removeObject(forKey: "agent.\(provider).keyHint") }
        else if let key { defaults.set(ChatSettings.maskedKey(key), forKey: "agent.\(provider).keyHint") }
        guard provider == settings.provider else { return }
        hasKey = saved
        restart()
    }

    nonisolated static func launch(root: URL, runtime: WorkspaceLocation?, settings: ChatSettings, apiKey: String?, environment inherited: [String: String], listModels: Bool = false) -> Launch {
        var environment = inherited.filter { !$0.key.hasPrefix("UI_ATLAS_") || $0.key == "UI_ATLAS_CONTROL_SOCKET" }
        environment["PATH"] = [runtime?.path, inherited["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"].compactMap { $0 }.joined(separator: ":")
        environment["UI_ATLAS_PROVIDER"] = settings.provider
        if !settings.model.isEmpty { environment["UI_ATLAS_MODEL"] = settings.model }
        if !settings.baseUrl.isEmpty { environment["UI_ATLAS_BASE_URL"] = settings.baseUrl }
        if let apiKey, !apiKey.isEmpty { environment["UI_ATLAS_API_KEY"] = apiKey }
        let script = root.appendingPathComponent("scripts/agent-chat.mjs").path
        let arguments = [script, "--root", root.path] + (listModels ? ["--list-models"] : [])
        if let node = runtime?.node {
            return Launch(executable: URL(fileURLWithPath: node), arguments: arguments, environment: environment)
        }
        return Launch(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node"] + arguments, environment: environment)
    }

    /// Reads the provider's model list with the harness's --list-models mode; the key is likewise passed only through an environment variable.
    nonisolated static func listModels(root: URL, runtime: WorkspaceLocation?, settings: ChatSettings, apiKey: String?) async -> Result<ModelListing, ModelListError> {
        let launch = Self.launch(root: root, runtime: runtime, settings: settings, apiKey: apiKey,
                                 environment: ProcessInfo.processInfo.environment, listModels: true)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let child = Process()
                child.executableURL = launch.executable
                child.arguments = launch.arguments
                child.environment = launch.environment
                child.currentDirectoryURL = root
                let output = Pipe()
                child.standardOutput = output
                child.standardError = FileHandle.nullDevice
                child.standardInput = FileHandle.nullDevice
                do { try child.run() } catch {
                    continuation.resume(returning: .failure(ModelListError(message: L("Cannot start the chat process: %@", error.localizedDescription))))
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                continuation.resume(returning: parseModelListing(data))
            }
        }
    }

    nonisolated static func parseModelListing(_ data: Data) -> Result<ModelListing, ModelListError> {
        let line = data.split(separator: UInt8(ascii: "\n")).first.map { Data($0) } ?? Data()
        let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        if event?["type"] as? String == "models", let models = event?["models"] as? [String] {
            return .success(ModelListing(models: models, defaultModel: event?["default"] as? String ?? ""))
        }
        if event?["type"] as? String == "error", let message = event?["message"] as? String {
            return .failure(ModelListError(message: message))
        }
        return .failure(ModelListError(message: L("The chat process returned no model list. Make sure you have run pnpm install in the project directory.")))
    }

    func send(_ text: String, root: URL?, runtime: WorkspaceLocation?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !transcript.busy else { return }
        transcript.send(trimmed)
        guard let root else { transcript.fail(L("Cannot find the ui-atlas source directory, so the chat process cannot start")); return }
        if process == nil {
            do { try start(root: root, runtime: runtime) }
            catch { transcript.fail(L("Cannot start the chat process: %@", error.localizedDescription)); return }
        }
        write(["type": "user", "text": trimmed])
    }

    func stopReply() { write(["type": "stop"]) }

    /// Not cleared while a reply is in progress, so the end event that arrives afterwards is not written into the new conversation.
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
        // terminate() discards the old harness's `done` and exit callbacks, so end the running reply here.
        transcript.stop()
        transcript.note(L("Model settings changed; new replies do not include the earlier context."))
    }

    private func start(root: URL, runtime: WorkspaceLocation?) throws {
        let launch = Self.launch(root: root, runtime: runtime, settings: settings, apiKey: storedKey(for: settings.provider),
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
        // Writing to stdin after the process has exited returns an error instead of sending SIGPIPE to the App.
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
        // The write fails when the process has exited; the App already ignores SIGPIPE, and the failure is reported by the termination handler.
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
        // The harness strips the key itself; nothing other than stderr is shown here.
        let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.fail(L("The chat process exited unexpectedly (%d). Make sure you have run pnpm install in the project directory.", status) + (detail.isEmpty ? "" : "\n\(detail)"))
    }

    private func terminate() {
        generation = UUID()
        // After stdin is closed, the harness aborts the current request and exits.
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
    }
}
