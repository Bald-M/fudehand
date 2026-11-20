import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

private let secret = "sk-ant-secret-0000-1111-9876"

/// A store whose chat session keeps its keys in `keychain` and its settings in its own defaults, and whose connectors use fake CLIs.
@MainActor
private final class Fixture {
    var keychain: [String: String] = [:]
    let defaults = UserDefaults(suiteName: "fudehand-settings-\(UUID().uuidString)")!
    var store: FudehandStore!

    /// `language` is saved before the store starts, so it starts in that language without setting the process-wide one.
    init(connectors: ConnectorsModel? = nil, language: AppLanguage? = nil) {
        let defaults = defaults
        language?.save(in: defaults)
        let chat = ChatSession(defaults: defaults, readKey: { [unowned self] in keychain[$0] }, writeKey: { [unowned self] in keychain[$1] = $0 },
                               deleteKey: { [unowned self] in keychain[$0] = nil })
        store = FudehandStore(defaults: defaults, chat: chat, connectors: connectors)
    }

    func run(_ command: ControlCommand) async throws -> [String: Any] {
        let result = try #require(try await store.handleControl(command) as? [String: Any])
        // No result ever carries a key.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        #expect(!text.contains(secret))
        return result
    }

    func failure(_ command: ControlCommand) async -> String? {
        do { _ = try await store.handleControl(command); return nil } catch { return error.localizedDescription }
    }
}

@Test @MainActor func settingsToolsReadAndChangeTheLanguageAndAppearance() async throws {
    // Only US English is assigned: assigning sets the process-wide `L10n.language`, which tests running in parallel read.
    let fixture = Fixture(language: .zhHant)
    let store = fixture.store!
    let read = try await fixture.run(.getInterface)
    #expect(read["language"] as? String == "zh-Hant" && read["appearance"] as? String == "system")
    #expect((read["languages"] as? [[String: String]])?.map { $0["id"]! } == ["en-US", "en-GB", "zh-Hans", "zh-Hant"])
    #expect(read["appearances"] as? [String] == ["system", "light", "dark"])

    let changed = try await fixture.run(.updateInterface(language: .enUS, appearance: .dark))
    // The same properties the menus bind to, saved where they save them.
    #expect(store.language == .enUS && store.theme == "dark")
    #expect(AppLanguage.saved(in: fixture.defaults) == .enUS && fixture.defaults.string(forKey: "native.theme") == "dark")
    #expect(changed["language"] as? String == "en-US" && changed["appearance"] as? String == "dark")
    let previous = try #require(changed["previous"] as? [String: Any])
    #expect(previous["language"] as? String == "zh-Hant" && previous["appearance"] as? String == "system")
    #expect((changed["note"] as? String)?.contains("restarts") == true)

    // Only the appearance: nothing waits for a restart.
    let appearance = try await fixture.run(.updateInterface(language: nil, appearance: .light))
    #expect(appearance["note"] == nil && store.theme == "light" && store.language == .enUS)
    #expect((appearance["previous"] as? [String: Any])?["appearance"] as? String == "dark")
}

@Test @MainActor func settingsToolsWriteKeysTheWaySaveDoesAndNeverReturnThem() async throws {
    let fixture = Fixture()
    let store = fixture.store!
    let saved = try await fixture.run(.setAPIKey("anthropic", key: secret))
    #expect(fixture.keychain == ["anthropic": secret])
    // The state the Model Settings sheet starts from.
    #expect(store.chat.draft().providers["anthropic"]?.hasSavedKey == true)
    let provider = try #require(saved["provider"] as? [String: Any])
    #expect(provider["hasKey"] as? Bool == true && provider["keyHint"] as? String == "sk-a••••••••9876")
    #expect((saved["previous"] as? [String: Any])?["hasKey"] as? Bool == false)
    #expect((saved["note"] as? String)?.contains("next message") == true)

    let models = try await fixture.run(.getModels)
    // The provider in use had no key, so the one that now has a key is used, as Save in the sheet does.
    #expect(models["inUse"] as? String == "anthropic")
    let anthropic = try #require((models["providers"] as? [[String: Any]])?.first { $0["id"] as? String == "anthropic" })
    #expect(anthropic["hasKey"] as? Bool == true && anthropic["keyHint"] as? String == "sk-a••••••••9876")

    let deleted = try await fixture.run(.deleteAPIKey("anthropic"))
    #expect(fixture.keychain.isEmpty && !store.chat.savedKey(for: "anthropic"))
    #expect((deleted["previous"] as? [String: Any])?["keyHint"] as? String == "sk-a••••••••9876")
    #expect(await fixture.failure(.deleteAPIKey("anthropic")) == "No API key is saved for Claude")
    #expect(await fixture.failure(.setAPIKey("gemini", key: secret)) == "provider must be one of deepseek, anthropic, openai; got gemini")
}

@Test @MainActor func settingsToolsChangeProvidersAndTheProviderInUse() async throws {
    let fixture = Fixture()
    let store = fixture.store!
    #expect(await fixture.failure(.updateModelProvider("openai", model: nil, baseUrl: nil, use: true))
            == "ChatGPT has no API key; save one with settings_set_api_key first")
    _ = try await fixture.run(.setAPIKey("deepseek", key: "sk-deepseek-0000-1111"))
    _ = try await fixture.run(.setAPIKey("openai", key: "sk-openai-2222-3333"))
    #expect(store.chat.settings.provider == "deepseek")

    let changed = try await fixture.run(.updateModelProvider("openai", model: " gpt-x ", baseUrl: "https://example.test/v1", use: true))
    #expect(store.chat.settings == ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    #expect(store.chat.stored("openai") == ChatSettings(provider: "openai", model: "gpt-x", baseUrl: "https://example.test/v1"))
    let provider = try #require(changed["provider"] as? [String: Any])
    #expect(provider["inUse"] as? Bool == true && provider["model"] as? String == "gpt-x")
    let previous = try #require(changed["previous"] as? [String: Any])
    #expect(previous["inUse"] as? Bool == false && previous["model"] as? String == "" && previous["baseUrl"] as? String == "")

    // An empty model is the provider's default model.
    _ = try await fixture.run(.updateModelProvider("openai", model: "", baseUrl: nil, use: false))
    #expect(store.chat.settings.model == "" && store.chat.settings.baseUrl == "https://example.test/v1")

    // Deleting the key of the provider in use falls back to the first one with a key, as the sheet does.
    let deleted = try await fixture.run(.deleteAPIKey("openai"))
    #expect(deleted["inUse"] as? String == "deepseek" && store.chat.settings.provider == "deepseek")
}

@Test @MainActor func settingsToolsListModelsWithTheSavedKey() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A stand-in harness: lists models for one base URL and fails, quoting the key, for any other.
    try Data("""
    const ok = process.env.FUDEHAND_BASE_URL === 'https://ok.test'
    console.log(JSON.stringify(ok ? { type: 'models', models: ['claude-a', 'claude-b'], default: 'claude-a', windows: { 'claude-a': 200000 } }
      : { type: 'error', message: `401 for ${process.env.FUDEHAND_API_KEY}` }))
    """.utf8).write(to: root.appendingPathComponent("scripts/agent-chat.mjs"))

    let fixture = Fixture()
    let store = fixture.store!
    store.toolsRoot = nil
    #expect(await fixture.failure(.listModels("anthropic", baseUrl: nil)) == "Cannot find the Fudehand source directory, so the model list is unavailable")
    store.toolsRoot = root
    #expect(await fixture.failure(.listModels("anthropic", baseUrl: nil)) == "No API key is saved for Claude; save one with settings_set_api_key first")
    _ = try await fixture.run(.setAPIKey("anthropic", key: secret))

    let failed = await fixture.failure(.listModels("anthropic", baseUrl: "https://bad.test"))
    #expect(failed == "Could not list Claude models: 401 for ***")
    #expect(store.chat.models(for: "anthropic").isEmpty)

    let listed = try await fixture.run(.listModels("anthropic", baseUrl: "https://ok.test"))
    #expect(listed["models"] as? [String] == ["claude-a", "claude-b"] && listed["defaultModel"] as? String == "claude-a")
    #expect((listed["previous"] as? [String: Any])?["models"] as? [String] == [])
    // Cached for the model menu, as a test from the settings sheet does.
    #expect(store.chat.models(for: "anthropic") == ["claude-a", "claude-b"])
    #expect(store.chat.contextWindow(provider: "anthropic", model: "") == 200000)
}

/// The codex CLI's registration, as in ConnectorsTests.
private actor FakeCodex {
    var registered = false
    var failAdd = false
    func run(_ arguments: [String]) -> CommandResult {
        switch arguments.prefix(2) {
        case ["mcp", "add"]:
            if failAdd { return CommandResult(exitCode: 1, output: Data(), error: "Error: config is read-only") }
            registered = true; return CommandResult(exitCode: 0, output: Data(), error: "")
        case ["mcp", "remove"]:
            registered = false; return CommandResult(exitCode: 0, output: Data(), error: "")
        default:
            guard registered else { return CommandResult(exitCode: 1, output: Data(), error: "No MCP server named 'fudehand' found.") }
            let json = try! JSONSerialization.data(withJSONObject: ["transport": ["command": "node", "args": ["/repo/scripts/mcp-server.mjs"]]])
            return CommandResult(exitCode: 0, output: json, error: "")
        }
    }
    func failNextAdds() { failAdd = true }
}

@Test @MainActor func settingsToolsConnectAndDisconnectConnectorsAndReportWhatChanged() async throws {
    let codex = FakeCodex()
    let connectors = ConnectorsModel(root: URL(fileURLWithPath: "/repo"), runtime: nil, inherited: ["PATH": "/tools", "DSH_HOME": "/nonexistent"],
                                     claudeConfig: URL(fileURLWithPath: "/nonexistent/.claude.json"), isExecutable: { $0 == "/tools/codex" }) { _, arguments, _ in
        await codex.run(arguments)
    }
    let fixture = Fixture(connectors: connectors)

    let read = try await fixture.run(.getConnectors)
    let states = try #require(read["connectors"] as? [[String: Any]])
    #expect(states.map { $0["status"] as? String } == ["unavailable", "disconnected", "unavailable"])

    let connected = try await fixture.run(.setConnector(.codex, connected: true))
    #expect((connected["connector"] as? [String: Any])?["status"] as? String == "connected")
    #expect((connected["previous"] as? [String: Any])?["status"] as? String == "disconnected")
    #expect(connected["command"] as? [String] == ["/tools/codex", "mcp", "add", "fudehand", "--", "node", "/repo/scripts/mcp-server.mjs"])
    // The window shows the same state.
    #expect(connectors.entries[.codex]?.status == .connected)

    let disconnected = try await fixture.run(.setConnector(.codex, connected: false))
    #expect(disconnected["command"] as? [String] == ["/tools/codex", "mcp", "remove", "fudehand"])
    #expect((disconnected["connector"] as? [String: Any])?["status"] as? String == "disconnected")

    await codex.failNextAdds()
    #expect(await fixture.failure(.setConnector(.codex, connected: true)) == "Connection failed: Error: config is read-only")
    #expect(await fixture.failure(.setConnector(.claude, connected: true)) == "The claude command was not found; install Claude Code first")
}
