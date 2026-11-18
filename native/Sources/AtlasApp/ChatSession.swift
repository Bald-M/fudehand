import AtlasCore
import Combine
import Foundation

/// The chat panel's model settings; excludes the API key (the key is in the Keychain).
struct ChatSettings: Equatable {
    static let providers: [(id: String, title: String)] = [("deepseek", "DeepSeek"), ("anthropic", "Claude"), ("openai", "ChatGPT")]

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

/// Manages the child processes of the in-App Agent harness (scripts/agent-chat.mjs): one per open conversation, started on demand,
/// exchanging JSON lines over stdin/stdout. After a conversation's settings or key change, its process is ended and the next message
/// restarts it with the new configuration.
/// Also owns the conversations: the ones open as tabs, and the saved ones that the history menu reopens.
@MainActor
final class ChatSession: ObservableObject {
    struct Launch {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    /// A conversation open in the panel, shown as a tab. `id` is the conversation's id in the history.
    struct Tab: Identifiable, Equatable {
        var id = UUID()
        var transcript = ChatTranscript()
        /// The model this conversation uses; a new conversation starts with the current one's.
        var settings: ChatSettings
    }

    /// The running harness process of one tab.
    private final class Harness {
        let token = UUID()
        let process: Process
        let input: FileHandle
        var buffer = Data()
        /// The last few lines of the harness's error output, shown when the process exits unexpectedly.
        var errorOutput = ""
        /// Whether the harness holds the conversation's history. False for a new process and after the conversation is rewound.
        var synced = false

        init(process: Process, input: FileHandle) {
            self.process = process
            self.input = input
        }
    }

    /// The open conversations, in tab order; never empty.
    @Published private(set) var tabs: [Tab]
    /// The selected tab's conversation.
    @Published private(set) var conversationID: UUID
    /// The saved conversations, newest first, for the history menu.
    @Published private(set) var conversations: [ChatHistory.Summary] = []

    private var current: Int { tabs.firstIndex { $0.id == conversationID } ?? 0 }
    var transcript: ChatTranscript { tabs[current].transcript }
    /// The selected conversation's model settings. Changing them restarts only that conversation's harness; they are also stored as
    /// what the next launch starts with.
    var settings: ChatSettings {
        get { tabs[current].settings }
        set {
            guard newValue != settings else { return }
            defaults.set(newValue.provider, forKey: "agent.provider")
            defaults.set(newValue.model, forKey: "agent.\(newValue.provider).model")
            defaults.set(newValue.baseUrl, forKey: "agent.\(newValue.provider).baseUrl")
            tabs[current].settings = newValue
            restart(conversationID)
        }
    }
    /// Whether the current provider's key is saved in the Keychain. Only a flag is recorded, so launch does not read the Keychain and trigger an authorization prompt.
    var hasKey: Bool { savedKey(for: settings.provider) }
    /// The current provider's model list as last fetched, for the model menu; kept so opening the panel does not read the Keychain.
    var models: [String] { models(for: settings.provider) }

    private let defaults: UserDefaults
    private let readKey: (String) -> String?
    private let writeKey: (String, String) throws -> Void
    private let deleteKey: (String) -> Void
    /// Where conversations are saved; nil keeps them in memory only.
    private let history: ChatHistory?
    /// The running harnesses, by tab id; a tab has none until its first message.
    private var harnesses: [UUID: Harness] = [:]

    /// The conversations saved for the current user, next to the control socket.
    nonisolated static var savedHistory: ChatHistory {
        ChatHistory(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ui-atlas/chats"))
    }

    init(defaults: UserDefaults = .standard, readKey: @escaping (String) -> String? = Keychain.read,
         writeKey: @escaping (String, String) throws -> Void = { try Keychain.save($0, account: $1) },
         deleteKey: @escaping (String) -> Void = Keychain.delete, history: ChatHistory? = nil) {
        self.defaults = defaults
        self.readKey = readKey
        self.writeKey = writeKey
        self.deleteKey = deleteKey
        self.history = history
        let provider = defaults.string(forKey: "agent.provider").flatMap { id in ChatSettings.providers.contains { $0.id == id } ? id : nil } ?? "deepseek"
        var tab = Tab(settings: Self.stored(provider, defaults))
        // Reopen the most recent conversation.
        let saved = history?.list() ?? []
        if let recent = saved.first.flatMap({ history?.load($0.id) }) {
            tab.id = recent.id
            tab.transcript = ChatTranscript(entries: recent.entries)
        }
        tabs = [tab]
        conversationID = tab.id
        conversations = saved
    }

    nonisolated static func stored(_ provider: String, _ defaults: UserDefaults) -> ChatSettings {
        ChatSettings(provider: provider, model: defaults.string(forKey: "agent.\(provider).model") ?? "",
                     baseUrl: defaults.string(forKey: "agent.\(provider).baseUrl") ?? "")
    }

    func stored(_ provider: String) -> ChatSettings { Self.stored(provider, defaults) }

    /// Saves `settings.provider`'s model and address. Conversations using that provider take the address, and the selected one the
    /// model too (the others keep the model chosen for them); those that changed restart their harness.
    func store(_ settings: ChatSettings) {
        defaults.set(settings.model, forKey: "agent.\(settings.provider).model")
        defaults.set(settings.baseUrl, forKey: "agent.\(settings.provider).baseUrl")
        objectWillChange.send()
        for index in tabs.indices where tabs[index].settings.provider == settings.provider {
            var changed = tabs[index].settings
            changed.baseUrl = settings.baseUrl
            if tabs[index].id == conversationID { changed.model = settings.model }
            guard changed != tabs[index].settings else { continue }
            tabs[index].settings = changed
            restart(tabs[index].id)
        }
    }

    func models(for provider: String) -> [String] { defaults.stringArray(forKey: "agent.\(provider).models") ?? [] }

    func defaultModel(for provider: String) -> String? {
        defaults.string(forKey: "agent.\(provider).defaultModel").flatMap { $0.isEmpty ? nil : $0 }
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
            objectWillChange.send()
        }
        return key
    }

    /// Called after a provider's key is saved to or deleted from the Keychain; only the conversations using that provider need their harness restarted.
    func keyUpdated(provider: String, saved: Bool, key: String? = nil) {
        defaults.set(saved, forKey: "agent.\(provider).hasKey")
        if !saved { defaults.removeObject(forKey: "agent.\(provider).keyHint") }
        else if let key { defaults.set(ChatSettings.maskedKey(key), forKey: "agent.\(provider).keyHint") }
        objectWillChange.send()
        for tab in tabs where tab.settings.provider == provider { restart(tab.id) }
    }

    /// The settings sheet's starting state, from the stored settings and key flags; reads no Keychain.
    func draft() -> ModelSettingsDraft {
        let providers = Dictionary(uniqueKeysWithValues: ChatSettings.providers.map { provider in
            let stored = stored(provider.id)
            return (provider.id, ProviderDraft(model: stored.model, baseUrl: stored.baseUrl, hasSavedKey: savedKey(for: provider.id)))
        })
        return ModelSettingsDraft(order: ChatSettings.providers.map(\.id), providers: providers, inUse: settings.provider)
    }

    /// Writes what the settings sheet's Save produced. A failed Keychain write stops before anything later is written,
    /// so the provider in use stays as it was; the harness restarts only when the provider in use, or its key or settings, changed.
    func apply(_ changes: ModelSettingsChanges) throws {
        for id in ChatSettings.providers.map(\.id) {
            guard let key = changes.saveKeys[id] else { continue }
            try writeKey(key, id)
            keyUpdated(provider: id, saved: true, key: key)
        }
        for id in changes.deleteKeys {
            deleteKey(id)
            keyUpdated(provider: id, saved: false)
        }
        for id in ChatSettings.providers.map(\.id) {
            guard let change = changes.settings[id] else { continue }
            store(ChatSettings(provider: id, model: change.model, baseUrl: change.baseUrl))
        }
        if changes.inUse != settings.provider { settings = stored(changes.inUse) }
    }

    /// Remembers a model list fetched for `provider`.
    func cacheModels(_ list: [String], defaultModel: String? = nil, provider: String) {
        defaults.set(list, forKey: "agent.\(provider).models")
        if let defaultModel, !defaultModel.isEmpty { defaults.set(defaultModel, forKey: "agent.\(provider).defaultModel") }
        objectWillChange.send()
    }

    /// Fetches the current provider's model list with the saved key (may trigger a Keychain authorization prompt).
    func reloadModels(root: URL?, runtime: WorkspaceLocation?) async {
        let settings = settings
        guard let root, let key = savedKeyValue(for: settings.provider) else { return }
        if case .success(let listing) = await Self.listModels(root: root, runtime: runtime, settings: settings, apiKey: key) {
            cacheModels(listing.models, defaultModel: listing.defaultModel, provider: settings.provider)
        }
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

    func send(_ text: String, context: [ChatContext] = [], root: URL?, runtime: WorkspaceLocation?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !transcript.busy else { return }
        let id = conversationID
        let earlier = transcript.messages
        update(id) { $0.send(trimmed, context: context) }
        // Saved before the reply arrives, so the message is not lost if the App quits unexpectedly.
        save(id)
        guard let root else { update(id) { $0.fail(L("Cannot find the ui-atlas source directory, so the chat process cannot start")) }; return }
        if harnesses[id] == nil {
            do { try start(id, root: root, runtime: runtime) }
            catch { update(id) { $0.fail(L("Cannot start the chat process: %@", error.localizedDescription)) }; return }
        }
        if let harness = harnesses[id], !harness.synced {
            write(["type": "load", "messages": earlier], to: id)
            harness.synced = true
        }
        write(["type": "user", "text": trimmed, "context": context.map { ["id": $0.id, "name": $0.name, "type": $0.type] }], to: id)
    }

    /// Stops the selected conversation's reply; replies in other tabs keep running.
    func stopReply() { write(["type": "stop"], to: conversationID) }

    /// Sends the last user message again, replacing the reply it got.
    func regenerate(root: URL?, runtime: WorkspaceLocation?) {
        guard let last = editLast() else { return }
        send(last.text, context: last.context, root: root, runtime: runtime)
    }

    /// Takes the last user message, and the reply to it, out of the conversation so the message can be edited and sent again.
    func editLast() -> ChatEntry? {
        let index = current
        guard let last = tabs[index].transcript.rewind() else { return nil }
        harnesses[conversationID]?.synced = false
        save(conversationID)
        return last
    }

    /// Opens an empty conversation in a new tab, using the current conversation's model. A tab that is already empty is selected instead of adding a second one.
    func newConversation() {
        if let empty = tabs.first(where: { $0.transcript.entries.isEmpty }) { conversationID = empty.id; return }
        let tab = Tab(settings: settings)
        tabs.append(tab)
        conversationID = tab.id
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        conversationID = id
    }

    /// Opens a saved conversation: selects its tab when it is already open, takes the place of an empty current conversation, or adds a tab.
    func open(_ id: UUID) {
        if tabs.contains(where: { $0.id == id }) { conversationID = id; return }
        guard let saved = history?.load(id) else { return }
        let tab = Tab(id: saved.id, transcript: ChatTranscript(entries: saved.entries), settings: settings)
        let index = current
        if tabs[index].transcript.entries.isEmpty {
            terminate(tabs[index].id)
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        conversationID = saved.id
    }

    /// Closes a tab, stopping its reply; the conversation stays in the history. Closing the last tab leaves an empty conversation.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        terminate(id)
        update(id) { $0.stop() }
        let closed = tabs.remove(at: index)
        if tabs.isEmpty { tabs.append(Tab(settings: closed.settings)) }
        if conversationID == id { conversationID = tabs[min(index, tabs.count - 1)].id }
    }

    /// Deletes the selected conversation from the history and closes its tab. Not while it is replying, so the reply is not saved again.
    func deleteConversation() {
        guard !transcript.busy else { return }
        let id = conversationID
        history?.delete(id)
        conversations = history?.list() ?? []
        close(id)
    }

    func shutdown() async {
        for tab in tabs {
            terminate(tab.id)
            // Keep what a reply cut short by quitting had already produced.
            update(tab.id) { $0.stop() }
        }
    }

    /// Changes a tab's transcript. A finished reply is saved at once, so the conversation survives a crash or a quit.
    private func update(_ id: UUID, _ change: (inout ChatTranscript) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasBusy = tabs[index].transcript.busy
        change(&tabs[index].transcript)
        if wasBusy && !tabs[index].transcript.busy { save(id) }
    }

    private func save(_ id: UUID) {
        guard let history, let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.transcript.entries.isEmpty { history.delete(id) }
        else { try? history.save(ChatConversation(id: id, transcript: tab.transcript, updatedAt: Date())) }
        conversations = history.list()
    }

    private func restart(_ id: UUID) {
        guard harnesses[id] != nil else { return }
        terminate(id)
        // terminate() discards the old harness's `done` and exit callbacks, so end the running reply here.
        // The next message starts a new harness, which is given the conversation so far.
        update(id) { $0.stop() }
    }

    private func start(_ id: UUID, root: URL, runtime: WorkspaceLocation?) throws {
        guard let settings = tabs.first(where: { $0.id == id })?.settings else { return }
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
        let harness = Harness(process: child, input: stdinPipe.fileHandleForWriting)
        // The callbacks name the tab and this harness, so output that arrives after the harness was replaced or its tab closed is dropped.
        let token = harness.token
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveError(data, tab: id, token: token) } }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data, tab: id, token: token) } }
        }
        child.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status, tab: id, token: token) } }
        }
        try child.run()
        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        harnesses[id] = harness
    }

    private func write(_ message: [String: Any], to id: UUID) {
        guard let input = harnesses[id]?.input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        // The write fails when the process has exited; the App already ignores SIGPIPE, and the failure is reported by the termination handler.
        try? input.write(contentsOf: data)
    }

    private func receive(_ data: Data, tab id: UUID, token: UUID) {
        guard let harness = harnesses[id], harness.token == token else { return }
        harness.buffer.append(data)
        while let newline = harness.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(harness.buffer[harness.buffer.startIndex..<newline])
            harness.buffer.removeSubrange(harness.buffer.startIndex...newline)
            update(id) { $0.apply(line) }
        }
    }

    private func receiveError(_ data: Data, tab id: UUID, token: UUID) {
        guard let harness = harnesses[id], harness.token == token else { return }
        harness.errorOutput = String((harness.errorOutput + String(decoding: data, as: UTF8.self)).suffix(600))
    }

    private func exited(_ status: Int32, tab id: UUID, token: UUID) {
        guard let harness = harnesses[id], harness.token == token else { return }
        harnesses[id] = nil
        guard tabs.first(where: { $0.id == id })?.transcript.busy == true else { return }
        // The harness strips the key itself; nothing other than stderr is shown here.
        let detail = harness.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.fail(L("The chat process exited unexpectedly (%d). Make sure you have run pnpm install in the project directory.", status) + (detail.isEmpty ? "" : "\n\(detail)")) }
    }

    private func terminate(_ id: UUID) {
        guard let harness = harnesses.removeValue(forKey: id) else { return }
        // After stdin is closed, the harness aborts the current request and exits.
        try? harness.input.close()
        harness.process.terminate()
    }
}
