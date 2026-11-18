import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func chatLaunchPassesTheKeyOnlyThroughTheEnvironment() {
    let settings = ChatSettings(provider: "anthropic", model: "claude-x", baseUrl: "http://127.0.0.1:9")
    let launch = ChatSession.launch(root: repository, runtime: WorkspaceLocation(root: repository.path, node: "/opt/node", path: "/opt/bin"),
                                    settings: settings, apiKey: "sk-secret", environment: ["PATH": "/usr/bin", "UI_ATLAS_API_KEY": "stale"])
    #expect(launch.executable == URL(fileURLWithPath: "/opt/node"))
    #expect(launch.arguments == [repository.appendingPathComponent("scripts/agent-chat.mjs").path, "--root", repository.path])
    #expect(!launch.arguments.joined().contains("sk-secret"))
    #expect(launch.environment["UI_ATLAS_API_KEY"] == "sk-secret")
    #expect(launch.environment["UI_ATLAS_PROVIDER"] == "anthropic")
    #expect(launch.environment["UI_ATLAS_MODEL"] == "claude-x")
    #expect(launch.environment["UI_ATLAS_BASE_URL"] == "http://127.0.0.1:9")
    #expect(launch.environment["PATH"]?.hasPrefix("/opt/bin:/usr/bin") == true)

    let unset = ChatSession.launch(root: repository, runtime: nil, settings: ChatSettings(provider: "deepseek", model: "", baseUrl: ""),
                                   apiKey: nil, environment: ["UI_ATLAS_API_KEY": "stale", "UI_ATLAS_MODEL": "stale"])
    #expect(unset.executable == URL(fileURLWithPath: "/usr/bin/env"))
    #expect(unset.arguments.first == "node")
    #expect(unset.environment["UI_ATLAS_API_KEY"] == nil)
    #expect(unset.environment["UI_ATLAS_MODEL"] == nil)
}

@Test @MainActor func chatSessionReportsAMissingKeyFromTheRealHarness() async throws {
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil })
    session.send("Hello", root: repository, runtime: nil)
    #expect(session.transcript.busy)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(!session.transcript.busy)
    #expect(session.transcript.entries.last?.text == "No API key configured")
    await session.shutdown()
}

@Test @MainActor func chatSettingsPersistPerProvider() {
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    #expect(session.settings.provider == "deepseek")
    session.settings = ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1")
    let reloaded = ChatSession(defaults: defaults, readKey: { _ in nil })
    #expect(reloaded.settings == ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { !$0.hasPrefix("sk-") })
}

@Test @MainActor func chatSessionReadsTheKeychainOnlyWhenStartingTheHarness() async throws {
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil })
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
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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

@Test @MainActor func chatSettingsChangeDuringAReplyEndsTheReply() async throws {
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil })
    session.send("Hello", root: repository, runtime: nil)
    #expect(session.transcript.busy)
    session.settings = ChatSettings(provider: "openai", model: "", baseUrl: "")
    #expect(!session.transcript.busy)
    #expect(session.transcript.entries.map(\.text) == ["Hello", "Reply stopped"])

    // The panel is usable again: a new message reaches a fresh harness, and the transcript can be cleared.
    session.send("Try again", root: repository, runtime: nil)
    #expect(session.transcript.busy)
    session.keyUpdated(provider: "openai", saved: false)
    #expect(!session.transcript.busy)
    session.send("Third time", root: repository, runtime: nil)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(session.transcript.entries.last?.text == "No API key configured")
    session.deleteConversation()
    #expect(session.transcript.entries.isEmpty)
    await session.shutdown()
}

@Test @MainActor func chatKeyFlagIsClearedWhenTheKeychainNoLongerHasTheKey() async throws {
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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
    ChatHistory(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-chats-\(UUID().uuidString)"))
}

@MainActor private func settle(_ session: ChatSession) async throws {
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(!session.transcript.busy)
}

@Test @MainActor func chatConversationsAreSavedAndReopenedAfterARelaunch() async throws {
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil }, history: history)
    session.send("Hello", root: repository, runtime: nil)
    await session.shutdown()
    #expect(history.list().map(\.title) == ["Hello"])
    #expect(history.load(session.conversationID)?.entries.map(\.text) == ["Hello", "Reply stopped"])
}

/// A stand-in harness that records what the App sends it and answers every user message with "ok".
private func recordingHarness() throws -> (root: URL, received: () throws -> [[String: Any]]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-harness-\(UUID().uuidString)")
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
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil }, history: history)
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
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    session.cacheModels(["deepseek-chat", "deepseek-reasoner"], provider: "deepseek")
    session.cacheModels(["gpt-x"], provider: "openai")
    #expect(session.models == ["deepseek-chat", "deepseek-reasoner"])
    session.settings = ChatSettings(provider: "openai", model: "", baseUrl: "")
    #expect(session.models == ["gpt-x"])
    #expect(ChatSession(defaults: defaults, readKey: { _ in nil }).models == ["gpt-x"])
}

@Test @MainActor func chatSettingsOfAnotherProviderAreStoredWithoutSwitching() async throws {
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
    let session = ChatSession(defaults: defaults, readKey: { _ in nil })
    session.send("Hello", root: repository, runtime: nil)
    session.store(ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    #expect(session.transcript.busy) // The running reply is left alone.
    #expect(session.settings.provider == "deepseek")
    #expect(session.stored("openai") == ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    session.store(ChatSettings(provider: "deepseek", model: "deepseek-reasoner", baseUrl: ""))
    #expect(session.settings.model == "deepseek-reasoner")
    #expect(!session.transcript.busy) // Changing the provider in use restarts the harness.
    await session.shutdown()
}

@Test @MainActor func chatModelCachesAreReadPerProvider() {
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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
    #expect(session.hasKey && !session.transcript.busy)
    await session.shutdown()
}

@Test @MainActor func aKeychainFailureLeavesTheProviderInUseUnchanged() {
    struct Refused: Error {}
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil },
                              writeKey: { _, _ in throw Refused() }, deleteKey: { _ in })
    var draft = session.draft()
    draft.setKey("sk-openai-2222-3333", for: "openai")
    #expect(draft.inUse == "openai")
    #expect(throws: Refused.self) { try session.apply(draft.changes()) }
    #expect(session.settings.provider == "deepseek" && !session.savedKey(for: "openai"))
}

@Test @MainActor func openingTheSettingsDraftDoesNotReadTheKeychain() {
    var reads = 0
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in reads += 1; return nil })
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-harness-\(UUID().uuidString)")
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
    ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil }, history: history)
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
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
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

    // Only the conversations using a provider are restarted when its key changes.
    session.keyUpdated(provider: "anthropic", saved: false)
    #expect(session.transcript.busy)
    session.keyUpdated(provider: "openai", saved: true)
    #expect(!session.transcript.busy)
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
