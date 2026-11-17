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
    #expect(session.transcript.entries.last?.text == "尚未配置 API key")
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
