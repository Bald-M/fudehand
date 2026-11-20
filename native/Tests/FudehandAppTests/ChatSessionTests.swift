import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func chatLaunchPassesTheKeyOnlyThroughTheEnvironment() {
    let settings = ChatSettings(provider: "anthropic", model: "claude-x", baseUrl: "http://127.0.0.1:9")
    let launch = ChatSession.launch(root: repository, runtime: WorkspaceLocation(root: repository.path, node: "/opt/node", path: "/opt/bin"),
                                    settings: settings, apiKey: "sk-secret", environment: ["PATH": "/usr/bin", "FUDEHAND_API_KEY": "stale"])
    #expect(launch.executable == URL(fileURLWithPath: "/opt/node"))
    #expect(launch.arguments == [repository.appendingPathComponent("scripts/agent-chat.mjs").path, "--root", repository.path])
    #expect(!launch.arguments.joined().contains("sk-secret"))
    #expect(launch.environment["FUDEHAND_API_KEY"] == "sk-secret")
    #expect(launch.environment["FUDEHAND_PROVIDER"] == "anthropic")
    #expect(launch.environment["FUDEHAND_MODEL"] == "claude-x")
    #expect(launch.environment["FUDEHAND_BASE_URL"] == "http://127.0.0.1:9")
    #expect(launch.environment["PATH"]?.hasPrefix("/opt/bin:/usr/bin") == true)

    let unset = ChatSession.launch(root: repository, runtime: nil, settings: ChatSettings(provider: "deepseek", model: "", baseUrl: ""),
                                   apiKey: nil, environment: ["FUDEHAND_API_KEY": "stale", "FUDEHAND_MODEL": "stale"])
    #expect(unset.executable == URL(fileURLWithPath: "/usr/bin/env"))
    #expect(unset.arguments.first == "node")
    #expect(unset.environment["FUDEHAND_API_KEY"] == nil)
    #expect(unset.environment["FUDEHAND_MODEL"] == nil)
}

@Test @MainActor func chatSessionReportsAMissingKeyFromTheRealHarness() async throws {
    let session = ChatSession(defaults: UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!, readKey: { _ in nil })
    session.send("Hello", root: repository, runtime: nil)
    #expect(session.transcript.busy)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(!session.transcript.busy)
    #expect(session.transcript.entries.last?.text == "No API key configured")
    await session.shutdown()
}

@Test @MainActor func chatSettingsPersistPerProvider() {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    #expect(session.settings.provider == "deepseek")
    session.settings = ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1")
    let reloaded = ChatSession(defaults: defaults, readKey: { _ in nil })
    #expect(reloaded.settings == ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { !$0.hasPrefix("sk-") })
}

@Test @MainActor func chatSessionReadsTheKeychainOnlyWhenStartingTheHarness() async throws {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    var reads: [String] = []
    let session = ChatSession(defaults: defaults, readKey: { reads.append($0); return nil })
    session.settings = ChatSettings(provider: "anthropic", model: "", baseUrl: "")
    #expect(reads.isEmpty)
    #expect(!session.hasKey)
    session.keyUpdated(provider: "anthropic", saved: true)
    #expect(session.hasKey)
    #expect(reads.isEmpty)
    session.send("Hello", root: repository, runtime: nil)
    #expect(reads == ["anthropic"])
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    await session.shutdown()
}

@Test @MainActor func chatKeyStatusIsTrackedPerProviderWithoutTheKey() {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    session.keyUpdated(provider: "openai", saved: true)
    #expect(!session.hasKey)
    session.settings = ChatSettings(provider: "openai", model: "", baseUrl: "")
    #expect(session.hasKey)
    #expect(ChatSession(defaults: defaults, readKey: { _ in nil }).hasKey)
    session.keyUpdated(provider: "openai", saved: false)
    #expect(!session.hasKey)
    #expect(session.transcript.entries.isEmpty)
}

@Test @MainActor func chatConversationIsNotDeletedWhileAReplyIsRunning() async throws {
    let session = ChatSession(defaults: UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!, readKey: { _ in nil })
    session.send("Hello", root: repository, runtime: nil)
    session.deleteConversation()
    #expect(session.transcript.entries.count == 1)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    session.deleteConversation()
    #expect(session.transcript.entries.isEmpty)
    await session.shutdown()
}

@Test func apiKeysAreMaskedKeepingOnlyTheEnds() {
    #expect(ChatSettings.maskedKey("sk-0123456789abcdef") == "sk-0••••••••cdef")
    #expect(ChatSettings.maskedKey("  sk-0123456789abcdef\n") == "sk-0••••••••cdef")
    #expect(ChatSettings.maskedKey("short-key") == "••••••••")
    #expect(ChatSettings.maskedKey("") == "")
}

@Test @MainActor func chatKeyHintIsStoredMaskedAndBackfilledFromTheKeychain() {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    var reads: [String] = []
    let session = ChatSession(defaults: defaults, readKey: { reads.append($0); return "sk-legacy-0000-9999" })
    session.keyUpdated(provider: "openai", saved: true, key: "sk-0123456789abcdef")
    #expect(session.keyHint(for: "openai") == "sk-0••••••••cdef")
    #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("0123456789") == true })
    session.keyUpdated(provider: "openai", saved: false)
    #expect(session.keyHint(for: "openai") == nil)
    #expect(session.savedKeyValue(for: "openai") == nil)
    #expect(reads.isEmpty)

    // A key saved by an older version has no hint; it is added the first time the Keychain is read.
    session.keyUpdated(provider: "anthropic", saved: true)
    #expect(session.keyHint(for: "anthropic") == nil)
    #expect(session.savedKeyValue(for: "anthropic") == "sk-legacy-0000-9999")
    #expect(session.keyHint(for: "anthropic") == "sk-l••••••••9999")
}

@Test func modelListingIsParsedFromTheHarnessOutput() {
    #expect(ChatSession.parseModelListing(Data(#"{"type":"models","models":["a","b"],"default":"a"}"#.utf8) + Data("\n".utf8))
            == .success(ModelListing(models: ["a", "b"], defaultModel: "a")))
    #expect(ChatSession.parseModelListing(Data(#"{"type":"models","models":["a","b"],"default":"a","windows":{"a":200000,"b":"big"}}"#.utf8))
            == .success(ModelListing(models: ["a", "b"], defaultModel: "a", windows: ["a": 200_000])))
    #expect(ChatSession.parseModelListing(Data(#"{"type":"error","message":"Invalid API key or insufficient permissions"}"#.utf8))
            == .failure(ModelListError(message: "Invalid API key or insufficient permissions")))
    #expect(ChatSession.parseModelListing(Data()) == .failure(ModelListError(message: "The chat process returned no model list. Make sure you have run pnpm install in the project directory.")))
}

@Test func modelListingRunsTheRealHarnessWithoutPuttingTheKeyInArguments() async {
    let settings = ChatSettings(provider: "deepseek", model: "", baseUrl: "http://127.0.0.1:9")
    let launch = ChatSession.launch(root: repository, runtime: nil, settings: settings, apiKey: "sk-secret", environment: [:], listModels: true)
    #expect(launch.arguments.last == "--list-models")
    #expect(!launch.arguments.joined().contains("sk-secret"))
    let missing = await ChatSession.listModels(root: repository, runtime: nil, settings: settings, apiKey: nil)
    #expect(missing == .failure(ModelListError(message: "No API key configured")))
}

@Test @MainActor func chatKeyFlagIsClearedWhenTheKeychainNoLongerHasTheKey() async throws {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    // The key was deleted outside the App: the flags still say a key is saved.
    session.keyUpdated(provider: "deepseek", saved: true, key: "sk-0123456789abcdef")
    session.keyUpdated(provider: "openai", saved: true, key: "sk-0123456789abcdef")
    #expect(session.hasKey)

    session.send("Hello", root: repository, runtime: nil)
    #expect(!session.hasKey)
    #expect(session.keyHint(for: "deepseek") == nil)
    #expect(!ChatSession(defaults: defaults, readKey: { _ in nil }).hasKey)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(session.transcript.entries.map(\.text) == ["Hello", "No API key configured"])

    // The settings sheet reads another provider's key the same way.
    #expect(session.savedKeyValue(for: "openai") == nil)
    #expect(!session.savedKey(for: "openai"))
    #expect(session.keyHint(for: "openai") == nil)
    await session.shutdown()
}

private func temporaryHistory() -> ChatHistory {
    ChatHistory(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-chats-\(UUID().uuidString)"))
}

@MainActor private func settle(_ session: ChatSession) async throws {
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(!session.transcript.busy)
}

@Test @MainActor func chatConversationsAreSavedAndReopenedAfterARelaunch() async throws {
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    #expect(session.conversations.isEmpty)
    session.send("First chat", root: repository, runtime: nil)
    try await settle(session)
    let first = session.conversationID
    session.newConversation()
    #expect(session.transcript.entries.isEmpty)
    // An empty conversation is not saved.
    #expect(session.conversations.map(\.title) == ["First chat"])
    session.send("Second chat", root: repository, runtime: nil)
    try await settle(session)
    #expect(session.conversations.map(\.title) == ["Second chat", "First chat"])
    await session.shutdown()

    // A relaunch reopens the most recent conversation and lists the others.
    let relaunched = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    #expect(relaunched.transcript.entries.map(\.text) == ["Second chat", "No API key configured"])
    #expect(relaunched.conversations.map(\.title) == ["Second chat", "First chat"])
    relaunched.open(first)
    #expect(relaunched.conversationID == first)
    #expect(relaunched.transcript.entries.map(\.text) == ["First chat", "No API key configured"])
    // Deleting it closes its tab, back to the conversation that was open beside it.
    relaunched.deleteConversation()
    #expect(relaunched.transcript.entries.map(\.text) == ["Second chat", "No API key configured"])
    #expect(relaunched.conversations.map(\.title) == ["Second chat"])
}

@Test @MainActor func chatReplyCutShortByQuittingIsSaved() async throws {
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = ChatSession(defaults: UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!, readKey: { _ in nil }, history: history)
    session.send("Hello", root: repository, runtime: nil)
    await session.shutdown()
    #expect(history.list().map(\.title) == ["Hello"])
    #expect(history.load(session.conversationID)?.entries.map(\.text) == ["Hello", "Reply stopped"])
}

/// A stand-in harness that records what the App sends it and answers every user message with "ok".
private func recordingHarness() throws -> (root: URL, received: () throws -> [[String: Any]]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let script = """
    import { createInterface } from 'node:readline'
    import { appendFileSync } from 'node:fs'
    createInterface({ input: process.stdin }).on('line', line => {
      appendFileSync(new URL('../received.jsonl', import.meta.url), line + '\\n')
      if (JSON.parse(line).type === 'user') process.stdout.write('{"type":"assistant","text":"ok"}\\n{"type":"done","stopped":false}\\n')
    })
    """
    try script.write(to: root.appendingPathComponent("scripts/agent-chat.mjs"), atomically: true, encoding: .utf8)
    return (root, {
        try String(contentsOf: root.appendingPathComponent("received.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    })
}

@Test @MainActor func chatSendsContextAndRestoresTheHistoryWhenItChanges() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = ChatSession(defaults: UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!, readKey: { _ in nil }, history: history)
    session.send("Make it blue", context: [ChatContext(id: "n1", name: "Hero", type: "frame")], root: harness.root, runtime: nil)
    try await settle(session)
    session.send("Now red", root: harness.root, runtime: nil)
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["Make it blue", "ok", "Now red", "ok"])

    // Regenerating replaces the last reply, and tells the harness the conversation up to that message.
    session.regenerate(root: harness.root, runtime: nil)
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["Make it blue", "ok", "Now red", "ok"])

    // Editing takes the last message back out; with nothing left, the saved conversation is removed.
    #expect(session.editLast()?.text == "Now red")
    #expect(session.editLast()?.context.map(\.name) == ["Hero"])
    #expect(session.transcript.entries.isEmpty)
    #expect(session.conversations.isEmpty)
    await session.shutdown()

    let received = try harness.received()
    #expect(received.map { $0["type"] as? String } == ["load", "user", "user", "load", "user"])
    #expect((received[0]["messages"] as? [[String: String]]) == [])
    #expect(received[1]["text"] as? String == "Make it blue")
    #expect((received[1]["context"] as? [[String: String]]) == [["id": "n1", "name": "Hero", "type": "frame"]])
    #expect((received[3]["messages"] as? [[String: String]]) == [["role": "user", "text": "Make it blue"], ["role": "assistant", "text": "ok"]])
    #expect(received[4]["text"] as? String == "Now red")
}

@Test @MainActor func chatModelListIsCachedPerProvider() {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    session.cacheModels(["deepseek-chat", "deepseek-reasoner"], provider: "deepseek")
    session.cacheModels(["gpt-x"], provider: "openai")
    #expect(session.models == ["deepseek-chat", "deepseek-reasoner"])
    session.settings = ChatSettings(provider: "openai", model: "", baseUrl: "")
    #expect(session.models == ["gpt-x"])
    #expect(ChatSession(defaults: defaults, readKey: { _ in nil }).models == ["gpt-x"])
}

@Test @MainActor func chatSettingsOfAnotherProviderAreStoredWithoutSwitching() async throws {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    session.send("Hello", root: repository, runtime: nil)
    session.store(ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    #expect(session.transcript.busy) // The running reply is left alone.
    #expect(session.settings.provider == "deepseek")
    #expect(session.stored("openai") == ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    session.store(ChatSettings(provider: "deepseek", model: "deepseek-reasoner", baseUrl: ""))
    #expect(session.settings.model == "deepseek-reasoner")
    #expect(session.transcript.busy) // The running reply finishes; the change applies from the next message.
    await session.shutdown()
}

@Test @MainActor func chatModelCachesAreReadPerProvider() {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    session.cacheModels(["gpt-x", "gpt-y"], defaultModel: "gpt-x", provider: "openai")
    session.cacheModels(["deepseek-chat"], provider: "deepseek")
    #expect(session.models(for: "openai") == ["gpt-x", "gpt-y"])
    #expect(session.defaultModel(for: "openai") == "gpt-x")
    #expect(session.defaultModel(for: "deepseek") == nil)
    #expect(session.models(for: "anthropic") == [])
    #expect(ChatSession(defaults: defaults, readKey: { _ in nil }).defaultModel(for: "openai") == "gpt-x")
}

@Test @MainActor func applyingSettingsWritesKeysAndLeavesOtherProvidersAlone() async throws {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    var keychain = ["deepseek": "sk-deepseek-0000-1111"]
    let session = ChatSession(defaults: defaults, readKey: { keychain[$0] }, writeKey: { keychain[$1] = $0 }, deleteKey: { keychain[$0] = nil })
    session.settings = ChatSettings(provider: "deepseek", model: "", baseUrl: "http://127.0.0.1:9")
    session.keyUpdated(provider: "deepseek", saved: true, key: "sk-deepseek-0000-1111")
    session.send("Hello", root: repository, runtime: nil)

    var draft = session.draft()
    #expect(draft.inUse == "deepseek" && draft.hasKey("deepseek") && !draft.hasKey("openai"))
    draft.setKey("sk-openai-2222-3333", for: "openai")
    draft.setModel("gpt-x", for: "openai")
    try session.apply(draft.changes())
    #expect(keychain == ["deepseek": "sk-deepseek-0000-1111", "openai": "sk-openai-2222-3333"])
    #expect(session.savedKey(for: "openai") && session.keyHint(for: "openai") == "sk-o••••••••3333")
    #expect(session.stored("openai").model == "gpt-x")
    #expect(session.settings.provider == "deepseek")
    #expect(session.transcript.busy) // Nothing about the provider in use changed.
    #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { !$0.contains("2222") })

    draft = session.draft()
    draft.removeKey("deepseek")
    try session.apply(draft.changes())
    #expect(keychain == ["openai": "sk-openai-2222-3333"])
    #expect(session.settings == ChatSettings(provider: "openai", model: "gpt-x", baseUrl: ""))
    #expect(session.hasKey && session.transcript.busy) // The running reply finishes; the change applies from the next message.
    await session.shutdown()
}

@Test @MainActor func aSettingsChangeDuringAReplyAppliesFromTheNextMessage() async throws {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    var keychain: [String: String] = [:]
    let session = ChatSession(defaults: defaults, readKey: { keychain[$0] }, writeKey: { keychain[$1] = $0 }, deleteKey: { keychain[$0] = nil })
    session.settings = ChatSettings(provider: "deepseek", model: "", baseUrl: "http://127.0.0.1:9")
    session.send("Hello", root: repository, runtime: nil)
    keychain["deepseek"] = "sk-deepseek-0000-1111"
    session.keyUpdated(provider: "deepseek", saved: true, key: "sk-deepseek-0000-1111")
    #expect(session.transcript.busy)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    // The reply ran to its end in the harness started without a key, rather than being stopped.
    #expect(session.transcript.entries.last?.text == "No API key configured")
    session.send("Again", root: repository, runtime: nil)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    // The next message runs in a new harness that has the key.
    #expect(!session.transcript.busy)
    #expect(session.transcript.entries.last?.text != "No API key configured")
    await session.shutdown()
}

@Test @MainActor func aKeychainFailureLeavesTheProviderInUseUnchanged() {
    struct Refused: Error {}
    let session = ChatSession(defaults: UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!, readKey: { _ in nil },
                              writeKey: { _, _ in throw Refused() }, deleteKey: { _ in })
    var draft = session.draft()
    draft.setKey("sk-openai-2222-3333", for: "openai")
    #expect(draft.inUse == "openai")
    #expect(throws: Refused.self) { try session.apply(draft.changes()) }
    #expect(session.settings.provider == "deepseek" && !session.savedKey(for: "openai"))
}

@Test @MainActor func openingTheSettingsDraftDoesNotReadTheKeychain() {
    var reads = 0
    let session = ChatSession(defaults: UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!, readKey: { _ in reads += 1; return nil })
    session.keyUpdated(provider: "openai", saved: true, key: "sk-0123456789abcdef")
    _ = session.draft()
    #expect(reads == 0)
}

@Test func modelProvidersAreNamedAfterTheirProducts() {
    #expect(ChatSettings.providers.map(\.id) == ["deepseek", "anthropic", "openai"])
    #expect(ChatSettings.providers.map(\.title) == ["DeepSeek", "Claude", "ChatGPT"])
}

/// A stand-in harness that records what the App sends it, with its process id. It answers a user message with "re: <text>" after a
/// moment, except "hang", which is only ever ended by a stop.
private func slowHarness() throws -> (root: URL, received: () throws -> [[String: Any]]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let script = """
    import { createInterface } from 'node:readline'
    import { appendFileSync } from 'node:fs'
    const emit = event => process.stdout.write(JSON.stringify(event) + '\\n')
    let timer = null
    const input = createInterface({ input: process.stdin })
    input.on('line', line => {
      const message = JSON.parse(line)
      appendFileSync(new URL('../received.jsonl', import.meta.url), JSON.stringify({ pid: process.pid, ...message }) + '\\n')
      if (message.type === 'user' && message.text !== 'hang') {
        timer = setTimeout(() => { emit({ type: 'assistant', text: 're: ' + message.text }); emit({ type: 'done', stopped: false }) }, 300)
      }
      if (message.type === 'stop') { clearTimeout(timer); emit({ type: 'done', stopped: true }) }
    })
    input.on('close', () => process.exit(0))
    """
    try script.write(to: root.appendingPathComponent("scripts/agent-chat.mjs"), atomically: true, encoding: .utf8)
    return (root, {
        try String(contentsOf: root.appendingPathComponent("received.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    })
}

/// Waits until the harness has recorded `count` messages, so its process ids are known.
private func received(_ harness: (root: URL, received: () throws -> [[String: Any]]), count: Int) async throws -> [[String: Any]] {
    for _ in 0..<100 {
        if let lines = try? harness.received(), lines.count >= count { return lines }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return try harness.received()
}

private func exited(_ pids: [Int32]) async throws -> Bool {
    for _ in 0..<50 where pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 100_000_000) }
    return !pids.contains { kill($0, 0) == 0 }
}

@MainActor private func temporarySession(history: ChatHistory? = nil) -> ChatSession {
    ChatSession(defaults: UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!, readKey: { _ in nil }, history: history)
}

@Test @MainActor func chatConversationsReplySideBySideWithoutSharingContext() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = temporarySession(history: history)
    #expect(session.tabs.count == 1)
    session.send("First", root: harness.root, runtime: nil)
    let first = session.conversationID

    // A new conversation opens beside the one that is replying, and can be used at once.
    session.newConversation()
    #expect(session.tabs.map(\.id) == [first, session.conversationID])
    #expect(session.conversationID != first)
    #expect(session.transcript.entries.isEmpty)
    session.send("Second", root: harness.root, runtime: nil)
    #expect(session.tabs.map(\.transcript.busy) == [true, true])
    for _ in 0..<100 where session.tabs.contains(where: \.transcript.busy) { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(session.tabs.map { $0.transcript.entries.map(\.text) } == [["First", "re: First"], ["Second", "re: Second"]])
    #expect(session.conversations.map(\.title).sorted() == ["First", "Second"])

    // Switching back continues the first conversation in its own harness.
    session.select(first)
    #expect(session.transcript.entries.map(\.text) == ["First", "re: First"])
    session.send("More", root: harness.root, runtime: nil)
    try await settle(session)
    await session.shutdown()

    let lines = try harness.received()
    #expect(Set(lines.compactMap { $0["pid"] as? Int }).count == 2)
    // Each harness was given an empty history: neither conversation starts with the other's messages.
    #expect(lines.filter { $0["type"] as? String == "load" }.map { ($0["messages"] as? [Any])?.count } == [0, 0])
    let firstPid = lines.first { $0["text"] as? String == "First" }?["pid"] as? Int
    #expect(lines.first { $0["text"] as? String == "More" }?["pid"] as? Int == firstPid)
    #expect(lines.first { $0["text"] as? String == "Second" }?["pid"] as? Int != firstPid)
}

@Test @MainActor func stoppingAReplyOnlyStopsTheCurrentConversationAndQuittingEndsEveryHarness() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.send("hang", root: harness.root, runtime: nil)
    session.newConversation()
    session.send("hang", root: harness.root, runtime: nil)
    let pids = Set(try await received(harness, count: 4).compactMap { ($0["pid"] as? Int).map { Int32($0) } })
    #expect(pids.count == 2)

    session.stopReply()
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["hang", "Reply stopped"])
    #expect(session.tabs[0].transcript.busy)

    await session.shutdown()
    #expect(session.tabs.map(\.transcript.busy) == [false, false])
    #expect(try await exited(Array(pids)))
}

@Test @MainActor func closingAConversationStopsItsReplyAndKeepsItInTheHistory() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = temporarySession(history: history)
    session.send("hang", root: harness.root, runtime: nil)
    let first = session.conversationID
    session.newConversation()
    session.send("Keep going", root: harness.root, runtime: nil)
    let second = session.conversationID
    let lines = try await received(harness, count: 4)
    let pid = Int32(try #require(lines.first { $0["text"] as? String == "hang" }?["pid"] as? Int))

    // Closing a tab in the background ends its harness and leaves the selected conversation alone.
    session.close(first)
    #expect(session.tabs.map(\.id) == [second])
    #expect(session.conversationID == second)
    #expect(history.load(first)?.entries.map(\.text) == ["hang", "Reply stopped"])
    #expect(try await exited([pid]))
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["Keep going", "re: Keep going"])

    // Closing the last conversation leaves an empty one; the closed one can be reopened from the history.
    session.close(second)
    #expect(session.tabs.count == 1)
    #expect(session.conversationID != second)
    #expect(session.transcript.entries.isEmpty)
    #expect(session.conversations.map(\.title).sorted() == ["Keep going", "hang"])
    session.open(first)
    #expect(session.tabs.map(\.id) == [first])
    await session.shutdown()
}

@Test @MainActor func eachConversationKeepsItsOwnModel() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    session.keyUpdated(provider: "anthropic", saved: true)
    let openai = ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "")
    let claude = ChatSettings(provider: "anthropic", model: "claude-x", baseUrl: "")
    session.settings = openai
    session.send("hang", root: harness.root, runtime: nil)
    let first = session.conversationID

    // A new conversation starts with the current one's model; changing it leaves the other conversation and its reply alone.
    session.newConversation()
    #expect(session.settings == openai)
    session.settings = claude
    #expect(session.hasKey)
    #expect(session.tabs.map(\.settings) == [openai, claude])
    #expect(session.tabs[0].transcript.busy)
    session.select(first)
    #expect(session.settings == openai)
    #expect(!session.hasKey)

    // An empty conversation that is reused takes the current model, like a new one.
    session.newConversation()
    #expect(session.tabs.count == 2 && session.settings == openai)

    // The settings sheet starts from the selected conversation's model, so saving another field does not replace it
    // with the model chosen last in another conversation; that conversation keeps its own model too.
    session.settings = ChatSettings(provider: "openai", model: "gpt-y", baseUrl: "")
    session.select(first)
    session.keyUpdated(provider: "openai", saved: true) // Without a key the sheet would move the chat to another provider.
    var draft = session.draft()
    #expect(draft.providers["openai"]?.model == "gpt-x")
    draft.setBaseUrl("https://example.test/v1", for: "openai")
    try session.apply(draft.changes())
    #expect(session.tabs.map(\.settings.model) == ["gpt-x", "gpt-y"])
    #expect(session.tabs.map(\.settings.baseUrl) == ["https://example.test/v1", "https://example.test/v1"])
    draft = session.draft()
    draft.setBaseUrl("", for: "openai")
    try session.apply(draft.changes())
    session.keyUpdated(provider: "openai", saved: false)
    session.select(session.tabs[1].id)
    session.settings = claude
    session.select(first)
    session.send("hang", root: harness.root, runtime: nil)

    // A key change never cuts a running reply short, for the provider it uses or another one: it applies from the next message.
    session.keyUpdated(provider: "anthropic", saved: false)
    #expect(session.transcript.busy)
    session.keyUpdated(provider: "openai", saved: true)
    #expect(session.transcript.busy)
    // The model chosen last is the one the next launch starts with.
    #expect(ChatSession(defaults: defaults, readKey: { _ in nil }).settings == claude)
    await session.shutdown()
}

@Test @MainActor func openingASavedConversationSelectsItsTabOrAddsOne() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = temporarySession(history: history)
    session.send("First", root: harness.root, runtime: nil)
    try await settle(session)
    let first = session.conversationID
    session.newConversation()
    // An empty conversation is reused rather than joined by another empty one.
    session.newConversation()
    #expect(session.tabs.count == 2)
    session.send("Second", root: harness.root, runtime: nil)
    try await settle(session)
    let second = session.conversationID
    session.close(first)

    // Reopened beside the current conversation, since that one has messages.
    session.open(first)
    #expect(session.tabs.map(\.id) == [second, first])
    #expect(session.conversationID == first)
    #expect(session.transcript.entries.map(\.text) == ["First", "re: First"])
    // Opening a conversation that is already open only selects its tab.
    session.open(second)
    #expect(session.tabs.map(\.id) == [second, first])
    #expect(session.conversationID == second)

    // Deleting closes the tab and removes the conversation from the history.
    session.deleteConversation()
    #expect(session.tabs.map(\.id) == [first])
    #expect(session.conversations.map(\.title) == ["First"])
    await session.shutdown()
}

// MARK: Conversations per design document

@Test @MainActor func chatTabsAndTheirModelsAreRestoredAfterARelaunch() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    defaults.set("https://proxy.example/v1", forKey: "agent.openai.baseUrl")
    let launch = { ChatSession(defaults: defaults, readKey: { _ in "sk-secret-test-key" }, history: history) }
    let session = launch()
    session.send("First", root: harness.root, runtime: nil)
    try await settle(session)
    let first = session.conversationID
    session.newConversation()
    session.settings = ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://proxy.example/v1")
    session.send("Second", root: harness.root, runtime: nil)
    try await settle(session)
    let second = session.conversationID
    session.select(first)
    await session.shutdown()

    // The tabs come back in order, each with its messages and model, and the same one selected.
    let relaunched = launch()
    #expect(relaunched.tabs.map(\.id) == [first, second])
    #expect(relaunched.conversationID == first)
    #expect(relaunched.tabs.map { $0.transcript.entries.map(\.text) } == [["First", "ok"], ["Second", "ok"]])
    #expect(relaunched.tabs.map(\.settings) == [ChatSettings(provider: "deepseek", model: "", baseUrl: ""),
                                                ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://proxy.example/v1")])

    // Neither the key nor the base URL is in what was saved.
    for file in try FileManager.default.contentsOfDirectory(at: history.directory, includingPropertiesForKeys: nil) {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("sk-secret-test-key"))
        #expect(!text.contains("proxy.example"))
    }

    // A closed conversation does not come back as a tab; it stays in the history.
    relaunched.close(first)
    let again = launch()
    #expect(again.tabs.map(\.id) == [second])
    #expect(again.conversations.map(\.title).sorted() == ["First", "Second"])
    // Reopened from the history, it uses the model it was saved with.
    again.open(first)
    #expect(again.settings.provider == "deepseek")
}

@Test @MainActor func chatRestoreSkipsUnreadableConversations() throws {
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    var transcript = ChatTranscript()
    transcript.send("Still here")
    transcript.stop()
    let good = ChatConversation(id: UUID(), transcript: transcript, updatedAt: Date(), provider: "gone", model: "m")
    try history.save(good)
    let damaged = UUID()
    try Data("not json".utf8).write(to: history.directory.appendingPathComponent("\(damaged.uuidString).json"))
    let missing = UUID()
    try history.saveOpenTabs(ChatHistory.OpenTabs(ids: [missing, damaged, good.id], selected: missing))
    let session = temporarySession(history: history)
    #expect(session.tabs.map(\.id) == [good.id])
    #expect(session.conversationID == good.id)
    // A provider this build does not know: the conversation uses the current settings.
    #expect(session.settings.provider == "deepseek")

    // Without a readable tab list the most recent conversation is reopened; closing it is remembered all the same.
    try Data("not json".utf8).write(to: history.directory.appendingPathComponent("tabs.json"))
    let fallback = temporarySession(history: history)
    #expect(fallback.tabs.map(\.id) == [good.id])
    fallback.close(good.id)
    #expect(temporarySession(history: history).transcript.entries.isEmpty)
    #expect(temporarySession(history: history).conversations.map(\.id) == [good.id])

    // Nothing readable at all: one empty conversation.
    let broken = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: broken.directory) }
    try FileManager.default.createDirectory(at: broken.directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: broken.directory.appendingPathComponent("tabs.json"))
    let empty = temporarySession(history: broken)
    #expect(empty.tabs.count == 1)
    #expect(empty.transcript.entries.isEmpty)
}

@Test @MainActor func chatShowsTheConversationsOfTheDocumentShown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-chats-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = ChatHistory.document(path: "/tmp/a.fudehand", root: root)
    let b = ChatHistory.document(path: "/tmp/b.fudehand", root: root)
    let session = temporarySession(history: a)
    session.send("About A", root: repository, runtime: nil)
    try await settle(session)
    let inA = session.conversationID

    session.show(b)
    #expect(session.tabs.count == 1)
    #expect(session.transcript.entries.isEmpty)
    #expect(session.conversations.isEmpty)
    session.send("About B", root: repository, runtime: nil)
    try await settle(session)

    session.show(a)
    #expect(session.tabs.map(\.id) == [inA])
    #expect(session.transcript.entries.first?.text == "About A")
    #expect(session.conversations.map(\.title) == ["About A"])
    // Nothing of B was written into A, and A's conversation cannot be opened from B.
    session.show(b)
    #expect(session.conversations.map(\.title) == ["About B"])
    session.open(inA)
    #expect(session.conversationID != inA)

    // A document without a file starts empty each time.
    let unsaved = ChatHistory.unsaved(root: root)
    session.show(unsaved, fresh: true)
    session.send("Scratch", root: repository, runtime: nil)
    try await settle(session)
    #expect(session.conversations.map(\.title) == ["Scratch"])
    session.show(unsaved, fresh: true)
    #expect(session.transcript.entries.isEmpty)
    #expect(session.conversations.isEmpty)

    // A document that was only looked at leaves nothing on disk.
    let c = ChatHistory.document(path: "/tmp/c.fudehand", root: root)
    session.show(c)
    session.newConversation()
    #expect(!FileManager.default.fileExists(atPath: c.directory.path))
}

@Test @MainActor func chatReplyRunningWhenTheDocumentChangesMovesWithIt() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-chats-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = ChatHistory.document(path: "/tmp/a.fudehand", root: root)
    let b = ChatHistory.document(path: "/tmp/b.fudehand", root: root)
    let session = temporarySession(history: a)
    session.send("Done", root: harness.root, runtime: nil)
    try await settle(session)
    session.newConversation()
    session.send("hang", root: harness.root, runtime: nil)
    let running = session.conversationID
    _ = try await received(harness, count: 4)

    // The reply acts on the document now shown, so its conversation is open there too; the idle one stays behind.
    session.show(b)
    #expect(session.tabs.map(\.id) == [running])
    #expect(session.conversationID == running)
    #expect(session.transcript.busy)
    #expect(b.list().map(\.id) == [running])
    #expect(b.openTabs()?.ids == [running])
    // The old document keeps the conversation as it was: nothing said about it is lost if the new document is never saved.
    #expect(a.list().map(\.title).sorted() == ["Done", "hang"])
    #expect(a.load(running)?.entries.map(\.text) == ["hang"])

    // Showing the same document again while the reply runs keeps the tabs in their order.
    session.newConversation()
    session.send("Later", root: harness.root, runtime: nil)
    try await settle(session)
    let later = session.conversationID
    session.select(running)
    session.show(b)
    #expect(session.tabs.map(\.id) == [running, later])
    #expect(session.tabs.map(\.transcript.busy) == [true, false])
    #expect(session.conversationID == running)

    session.stopReply()
    try await settle(session)
    #expect(b.load(running)?.entries.map(\.text) == ["hang", "Reply stopped"])
    await session.shutdown()
}

@Test @MainActor func chatConversationsFollowTheDocumentWhenItIsSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-chats-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let unsaved = ChatHistory.unsaved(root: root)
    let document = ChatHistory.document(path: "/tmp/a.fudehand", root: root)
    let session = temporarySession(history: unsaved)
    session.send("Draft", root: repository, runtime: nil)
    try await settle(session)
    let id = session.conversationID

    // The first save moves the conversations to the file.
    session.rebind(to: document, moving: true)
    #expect(document.list().map(\.title) == ["Draft"])
    #expect(!FileManager.default.fileExists(atPath: unsaved.directory.path))
    #expect(session.conversations.map(\.title) == ["Draft"])
    session.send("More", root: repository, runtime: nil)
    try await settle(session)
    #expect(document.load(id)?.entries.contains { $0.text == "More" } == true)
    #expect(temporarySession(history: document).tabs.map(\.id) == [id])

    // Save As copies them; the original file keeps its own.
    let copy = ChatHistory.document(path: "/tmp/copy.fudehand", root: root)
    session.rebind(to: copy, moving: false)
    #expect(document.list().map(\.id) == [id])
    #expect(copy.list().map(\.id) == [id])
    #expect(copy.openTabs()?.ids == [id])

    // Saving onto a file that already has an older copy of an open conversation: what is open is what is kept.
    session.send("Newest", root: repository, runtime: nil)
    try await settle(session)
    session.rebind(to: document, moving: false)
    #expect(document.load(id)?.entries.contains { $0.text == "Newest" } == true)
}

/// A stand-in harness that answers every user message with a question, and continues once the question is answered.
private func askingHarness() throws -> (root: URL, received: () throws -> [[String: Any]]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let script = """
    import { createInterface } from 'node:readline'
    import { appendFileSync } from 'node:fs'
    const emit = event => process.stdout.write(JSON.stringify(event) + '\\n')
    let asked = false
    const input = createInterface({ input: process.stdin })
    input.on('line', line => {
      const message = JSON.parse(line)
      appendFileSync(new URL('../received.jsonl', import.meta.url), JSON.stringify({ pid: process.pid, ...message }) + '\\n')
      if (message.type === 'user') {
        asked = true
        emit({ type: 'question', id: 'q1', question: 'How many entries?', options: [{ label: '3 entries' }, { label: '4 entries' }] })
      }
      if (message.type === 'answer') {
        emit({ type: 'assistant', text: (asked ? 'continued: ' : 'resumed: ') + (message.skipped ? 'skipped' : message.text) })
        emit({ type: 'done', stopped: false })
        asked = false
      }
      if (message.type === 'stop') emit({ type: 'done', stopped: true })
    })
    input.on('close', () => process.exit(0))
    """
    try script.write(to: root.appendingPathComponent("scripts/agent-chat.mjs"), atomically: true, encoding: .utf8)
    return (root, {
        try String(contentsOf: root.appendingPathComponent("received.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    })
}

@MainActor private func waiting(_ session: ChatSession) async throws {
    for _ in 0..<100 where !session.transcript.waiting { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(session.transcript.waiting)
}

@Test @MainActor func answeringAQuestionContinuesTheReplyWithoutBlockingOtherConversations() async throws {
    let harness = try askingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.send("Add a bottom navigation", root: harness.root, runtime: nil)
    try await waiting(session)
    let first = session.conversationID
    #expect(session.transcript.busy)

    // Another conversation is not held up by the question.
    session.newConversation()
    session.send("Other", root: harness.root, runtime: nil)
    try await waiting(session)
    session.answer(nil, root: harness.root, runtime: nil)
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["Other", "How many entries?", "continued: skipped"])
    #expect(session.tabs[0].transcript.waiting)

    session.select(first)
    session.answer("3 entries", root: harness.root, runtime: nil)
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["Add a bottom navigation", "How many entries?", "continued: 3 entries"])
    #expect(session.transcript.entries[1].question?.state == .answered("3 entries"))
    await session.shutdown()

    let answers = try harness.received().filter { $0["type"] as? String == "answer" }
    #expect(answers.map { $0["id"] as? String } == ["q1", "q1"])
    #expect(answers.last?["text"] as? String == "3 entries")
    #expect(answers.last?["question"] as? String == "How many entries?")
}

@Test @MainActor func stoppingTheReplyCancelsTheQuestion() async throws {
    let harness = try askingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.send("Add a bottom navigation", root: harness.root, runtime: nil)
    try await waiting(session)
    session.stopReply()
    try await settle(session)
    #expect(!session.transcript.waiting)
    #expect(session.transcript.entries[1].question?.state == .cancelled)
    // Nothing is left to answer.
    session.answer("3 entries", root: harness.root, runtime: nil)
    #expect(!session.transcript.busy)
    await session.shutdown()
    #expect(try harness.received().filter { $0["type"] as? String == "answer" }.isEmpty)
}

@Test @MainActor func anUnansweredQuestionSurvivesQuittingAndIsAnsweredAfterARelaunch() async throws {
    let harness = try askingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    session.send("Add a bottom navigation", root: harness.root, runtime: nil)
    try await waiting(session)
    // Saved as soon as it is asked, so it is not lost if the App quits unexpectedly.
    #expect(history.load(session.conversationID)?.entries.last?.question?.state == .pending)
    await session.shutdown()
    #expect(history.load(session.conversationID)?.entries.map(\.text) == ["Add a bottom navigation", "How many entries?"])

    let relaunched = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    #expect(relaunched.transcript.waiting)
    #expect(!relaunched.transcript.busy)
    relaunched.answer("4 entries", root: harness.root, runtime: nil)
    #expect(relaunched.transcript.busy)
    try await settle(relaunched)
    #expect(relaunched.transcript.entries.map(\.text) == ["Add a bottom navigation", "How many entries?", "resumed: 4 entries"])
    await relaunched.shutdown()

    // The new harness is given the conversation so far, then the answer.
    let lines = try harness.received()
    let pid = lines.last?["pid"] as? Int
    let resumed = lines.filter { $0["pid"] as? Int == pid }
    #expect(resumed.map { $0["type"] as? String } == ["load", "answer"])
    #expect((resumed[0]["messages"] as? [[String: String]]) == [["role": "user", "text": "Add a bottom navigation"]])
    #expect(history.load(relaunched.conversationID)?.entries.last?.text == "resumed: 4 entries")
}

@Test @MainActor func aPlanReplysQuestionIsStillAnsweredInPlanModeAfterARelaunchOrReopenedTab() async throws {
    let harness = try askingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    session.mode = .plan
    session.send("Add a bottom navigation", root: harness.root, runtime: nil)
    try await waiting(session)
    #expect(history.load(session.conversationID)?.replyMode == .plan)
    await session.shutdown()

    // After a relaunch the answer still cannot edit the document: it continues the plan, which is then ready to run.
    let relaunched = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    #expect(relaunched.mode == .plan)
    relaunched.answer("4 entries", root: harness.root, runtime: nil)
    try await settle(relaunched)
    #expect(relaunched.planReady)
    // Once nothing waits, the mode is no longer saved.
    #expect(history.load(relaunched.conversationID)?.replyMode == nil)

    // The same after closing the tab and reopening the conversation from the history.
    relaunched.send("Fewer entries", root: harness.root, runtime: nil)
    try await waiting(relaunched)
    let id = relaunched.conversationID
    relaunched.close(id)
    relaunched.open(id)
    #expect(relaunched.mode == .plan)
    relaunched.answer("3 entries", root: harness.root, runtime: nil)
    try await settle(relaunched)
    await relaunched.shutdown()

    let answers = try harness.received().filter { $0["type"] as? String == "answer" }
    #expect(answers.map { $0["mode"] as? String } == ["plan", "plan"])
}

@Test @MainActor func closingATabKeepsItsQuestionOpen() async throws {
    let harness = try askingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = temporarySession(history: history)
    session.send("Add a bottom navigation", root: harness.root, runtime: nil)
    try await waiting(session)
    let id = session.conversationID
    session.close(id)
    #expect(history.load(id)?.entries.last?.question?.state == .pending)
    session.open(id)
    #expect(session.transcript.waiting)
    await session.shutdown()
}

// MARK: Slash commands and modes

@Test @MainActor func chatPlanModeIsSentWithEachMessageUntilThePlanIsRun() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.mode = .plan
    #expect(!session.planReady)
    session.send("A login screen", root: harness.root, runtime: nil)
    #expect(!session.planReady)
    try await settle(session)
    // The reply is the plan: the mode stays on, and the plan can be run.
    #expect(session.mode == .plan && session.planReady)
    session.runPlan(root: harness.root, runtime: nil)
    #expect(session.mode == nil && !session.planReady)
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["A login screen", "ok", "Carry out the plan.", "ok"])
    await session.shutdown()

    let received = try harness.received().filter { $0["type"] as? String == "user" }
    #expect(received.map { $0["mode"] as? String } == ["plan", nil])
}

@Test @MainActor func chatLeavingPlanModeWithdrawsThePlan() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.mode = .plan
    session.send("A login screen", root: harness.root, runtime: nil)
    try await settle(session)
    session.mode = nil
    #expect(!session.planReady)
    session.runPlan(root: harness.root, runtime: nil)
    #expect(!session.transcript.busy && session.transcript.entries.count == 2)
    await session.shutdown()
}

@Test @MainActor func chatGoalModeEndsWithTheReplyAndBelongsToItsConversation() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.mode = .goal
    session.send("Finish the page", root: harness.root, runtime: nil)
    #expect(session.mode == .goal)
    let first = session.conversationID
    session.newConversation()
    #expect(session.mode == nil)
    session.select(first)
    try await settle(session)
    #expect(session.mode == nil)
    session.send("Thanks", root: harness.root, runtime: nil)
    try await settle(session)
    await session.shutdown()

    let received = try harness.received().filter { $0["type"] as? String == "user" }
    #expect(received.map { $0["mode"] as? String } == ["goal", nil])
}

@Test @MainActor func chatClearingAConversationEmptiesItInPlace() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = temporarySession(history: history)
    session.mode = .plan
    session.send("A login screen", root: harness.root, runtime: nil)
    try await settle(session)
    let id = session.conversationID
    #expect(session.conversations.count == 1)
    session.clearConversation()
    #expect(session.conversationID == id && session.tabs.count == 1)
    #expect(session.transcript.entries.isEmpty && session.conversations.isEmpty)
    #expect(session.mode == nil && !session.planReady)

    // The harness is told the conversation starts over.
    session.send("Again", root: harness.root, runtime: nil)
    try await settle(session)
    await session.shutdown()
    let received = try harness.received()
    #expect((received.last { $0["type"] as? String == "load" }?["messages"] as? [[String: String]]) == [])
    #expect(received.last?["text"] as? String == "Again")

}

@Test @MainActor func chatClearingStopsARunningReply() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.send("Hello", root: harness.root, runtime: nil)
    let pid = try #require(try await received(harness, count: 2).last?["pid"] as? Int)
    #expect(session.transcript.busy)
    session.clearConversation()
    #expect(!session.transcript.busy && session.transcript.entries.isEmpty)
    // The harness is gone, and the reply it was about to send does not land in the emptied conversation.
    #expect(try await exited([Int32(pid)]))
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(session.transcript.entries.isEmpty)
    await session.shutdown()
}

@Test @MainActor func chatACommandRunDuringAReplyAppliesToTheNextMessage() async throws {
    let harness = try slowHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    // Plan mode chosen while an ordinary reply runs: that reply is not a plan.
    session.send("Make it blue", root: harness.root, runtime: nil)
    session.mode = .plan
    try await settle(session)
    #expect(session.mode == .plan && !session.planReady)
    // Goal mode chosen while the plan is being made: it is still on for the goal that follows.
    session.send("A login screen", root: harness.root, runtime: nil)
    session.mode = .goal
    try await settle(session)
    #expect(session.mode == .goal && !session.planReady)
    session.send("Finish the page", root: harness.root, runtime: nil)
    try await settle(session)
    #expect(session.mode == nil)
    await session.shutdown()

    let sent = try harness.received().filter { $0["type"] as? String == "user" }
    #expect(sent.map { $0["mode"] as? String } == [nil, "plan", "goal"])
}

@Test @MainActor func contextWindowFollowsTheModelOfTheSelectedConversation() {
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    #expect(session.contextUsage == ContextUsage(used: 0, window: nil))
    session.cacheModels(["deepseek-flash", "deepseek-v4-pro"], defaultModel: "deepseek-flash", windows: ["deepseek-flash": 1_048_576, "deepseek-v4-pro": 524_288], provider: "deepseek")
    session.cacheModels(["gpt-x"], defaultModel: "gpt-x", provider: "openai")
    // An empty model means the provider's default.
    #expect(session.contextUsage.window == 1_048_576)
    session.settings = ChatSettings(provider: "deepseek", model: "deepseek-v4-pro", baseUrl: "")
    #expect(session.contextUsage.window == 524_288)
    session.settings = ChatSettings(provider: "deepseek", model: "something-else", baseUrl: "")
    #expect(session.contextUsage.window == nil)
    // A list that reports no windows leaves none behind.
    session.settings = ChatSettings(provider: "openai", model: "", baseUrl: "")
    #expect(session.contextUsage.window == nil)
    #expect(ChatSession(defaults: defaults, readKey: { _ in nil }).contextWindow(provider: "deepseek", model: "") == 1_048_576)
}

/// A stand-in harness that records what the App sends it, answers a user message with "ok", and a compact with a summary.
private func compactingHarness() throws -> (root: URL, received: () throws -> [[String: Any]]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let script = """
    import { createInterface } from 'node:readline'
    import { appendFileSync } from 'node:fs'
    createInterface({ input: process.stdin }).on('line', line => {
      appendFileSync(new URL('../received.jsonl', import.meta.url), line + '\\n')
      const type = JSON.parse(line).type
      if (type === 'user') process.stdout.write('{"type":"assistant","text":"ok"}\\n{"type":"done","stopped":false,"context":5000}\\n')
      if (type === 'compact') process.stdout.write('{"type":"compacted","summary":"All blue."}\\n{"type":"done","stopped":false,"context":40}\\n')
    })
    """
    try script.write(to: root.appendingPathComponent("scripts/agent-chat.mjs"), atomically: true, encoding: .utf8)
    return (root, {
        try String(contentsOf: root.appendingPathComponent("received.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    })
}

@Test @MainActor func compactingKeepsTheMessagesAndRestoresTheHarnessFromTheSummary() async throws {
    let harness = try compactingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let defaults = UserDefaults(suiteName: "fudehand-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    // Nothing to compact yet: no harness is started for it.
    session.compact(root: harness.root, runtime: nil)
    #expect(!session.transcript.busy)
    session.send("Make it blue", root: harness.root, runtime: nil)
    try await settle(session)
    #expect(session.contextUsage.used == 5000)
    session.compact(root: harness.root, runtime: nil)
    #expect(session.transcript.compacting)
    try await settle(session)
    #expect(session.transcript.entries.map(\.text) == ["Make it blue", "ok", "All blue."])
    #expect(session.contextUsage.used == 40)
    await session.shutdown()

    // The compaction is saved: after a relaunch the messages are shown, and a new harness is given the summary instead of them.
    let relaunched = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    #expect(relaunched.transcript.entries.map(\.kind) == [.user, .assistant, .summary])
    #expect(relaunched.contextUsage.used == 40)
    relaunched.send("Which color?", root: harness.root, runtime: nil)
    try await settle(relaunched)
    await relaunched.shutdown()
    // A conversation reopened without a running harness can be compacted too: the harness is given the conversation first.
    let again = ChatSession(defaults: defaults, readKey: { _ in nil }, history: history)
    again.compact(root: harness.root, runtime: nil)
    try await settle(again)
    #expect(again.transcript.entries.map(\.kind) == [.user, .assistant, .summary, .user, .assistant, .summary])
    await again.shutdown()

    let received = try harness.received()
    #expect(received.map { $0["type"] as? String } == ["load", "user", "compact", "load", "user", "load", "compact"])
    #expect((received[3]["messages"] as? [[String: String]]) == [["role": "summary", "text": "All blue."]])
    #expect((received[5]["messages"] as? [[String: String]]) == [["role": "summary", "text": "All blue."], ["role": "user", "text": "Which color?"], ["role": "assistant", "text": "ok"]])
}

@Test @MainActor func chatRegeneratingTheReplyToAGoalWorksOnTheGoalAgain() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.mode = .goal
    session.send("Finish the page", root: harness.root, runtime: nil)
    try await settle(session)
    #expect(session.mode == nil)
    session.regenerate(root: harness.root, runtime: nil)
    #expect(session.mode == .goal)
    try await settle(session)
    #expect(session.mode == nil)
    // An ordinary reply is regenerated as one.
    session.send("Thanks", root: harness.root, runtime: nil)
    try await settle(session)
    session.regenerate(root: harness.root, runtime: nil)
    try await settle(session)
    await session.shutdown()

    let sent = try harness.received().filter { $0["type"] as? String == "user" }
    #expect(sent.map { $0["mode"] as? String } == ["goal", "goal", nil, nil])
}

@Test @MainActor func chatRunningAPlanSendsTheSelectedLayers() async throws {
    let harness = try recordingHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let session = temporarySession()
    session.mode = .plan
    session.send("Make it blue", root: harness.root, runtime: nil)
    try await settle(session)
    session.runPlan(context: [ChatContext(id: "n1", name: "Hero", type: "frame")], root: harness.root, runtime: nil)
    try await settle(session)
    await session.shutdown()

    let sent = try harness.received().filter { $0["type"] as? String == "user" }
    #expect((sent.last?["context"] as? [[String: String]]) == [["id": "n1", "name": "Hero", "type": "frame"]])
    #expect(session.transcript.entries.last { $0.kind == .user }?.context.map(\.name) == ["Hero"])
}
