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

@Test @MainActor func chatConversationIsNotReplacedWhileAReplyIsRunning() async throws {
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil })
    session.send("Hello", root: repository, runtime: nil)
    session.deleteConversation()
    session.newConversation()
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
    relaunched.deleteConversation()
    #expect(relaunched.transcript.entries.isEmpty)
    #expect(relaunched.conversations.map(\.title) == ["Second chat"])
}

@Test @MainActor func chatReplyCutShortByQuittingIsSaved() async throws {
    let history = temporaryHistory()
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil }, history: history)
    session.send("Hello", root: repository, runtime: nil)
    await session.shutdown()
    #expect(history.list().map(\.title) == ["Hello"])
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
