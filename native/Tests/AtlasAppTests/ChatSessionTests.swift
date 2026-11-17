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
    session.send("你好", root: repository, runtime: nil)
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
    session.send("你好", root: repository, runtime: nil)
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

@Test @MainActor func chatClearIsIgnoredWhileAReplyIsRunning() async throws {
    let session = ChatSession(defaults: UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!, readKey: { _ in nil })
    session.send("你好", root: repository, runtime: nil)
    session.clear()
    #expect(session.transcript.entries.count == 1)
    for _ in 0..<100 where session.transcript.busy { try await Task.sleep(nanoseconds: 100_000_000) }
    session.clear()
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

    // 旧版本保存的 key 没有提示，第一次读取钥匙串时补上。
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
    #expect(ChatSession.parseModelListing(Data()) == .failure(ModelListError(message: "对话程序没有返回模型列表，请确认已在项目目录执行 pnpm install。")))
}

@Test func modelListingRunsTheRealHarnessWithoutPuttingTheKeyInArguments() async {
    let settings = ChatSettings(provider: "deepseek", model: "", baseUrl: "http://127.0.0.1:9")
    let launch = ChatSession.launch(root: repository, runtime: nil, settings: settings, apiKey: "sk-secret", environment: [:], listModels: true)
    #expect(launch.arguments.last == "--list-models")
    #expect(!launch.arguments.joined().contains("sk-secret"))
    let missing = await ChatSession.listModels(root: repository, runtime: nil, settings: settings, apiKey: nil)
    #expect(missing == .failure(ModelListError(message: "No API key configured")))
}
