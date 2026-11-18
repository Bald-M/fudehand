# Multi-Provider Model Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The chat panel's model settings show every model provider side by side, can test an API key, and the model menu switches between the models of all configured providers (#133).

**Architecture:** Two pure rules go into `AtlasCore`: `ModelMenu` (providers + caches + selection → menu sections) and `ModelSettingsDraft` (the settings sheet's unsaved state and what *Save* writes). `ChatSession` gains per-provider reads and writes and an `apply` that performs a draft's changes. `ChatPanel.swift` renders both; the storage keys and the harness are unchanged.

**Tech Stack:** Swift 6 toolchain (Swift 5 language mode), SwiftUI, swift-testing. No new packages.

**Spec:** `docs/superpowers/specs/2026-11-18-multi-provider-model-settings-design.md`

## Global Constraints

- Provider ids stay `deepseek`, `anthropic`, `openai`; titles become `DeepSeek`, `Claude`, `ChatGPT` and are not localized.
- Storage is unchanged: Keychain service `ui-atlas.agent`, account = provider id; UserDefaults `agent.provider`, `agent.<id>.model`, `.baseUrl`, `.hasKey`, `.keyHint`, `.models`. One key is added: `agent.<id>.defaultModel`.
- An API key never reaches UserDefaults, logs, or process arguments.
- Opening the sheet, selecting a provider in it, and opening the model menu do not read the Keychain. The only Keychain reads are *Test* with a saved key, *Reload Model List*, and starting the harness.
- Nothing in the sheet is written before *Save*, except the model list cached by a passed test.
- UI copy: `L("English text")` plus an entry in all four tables under `native/Sources/AtlasCore/Resources/`; Chinese terms follow `GLOSSARY.md` (模型提供方 / 模型提供者). Code comments, test names, and docs are English.
- Model menu fold threshold: more than 8 cached models.
- Another session builds in the main checkout. Run every Swift command with `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-native-133` so the scratch directories do not collide.
- Commits: Conventional Commits with a Chinese summary, scope `chat`, ending with the session's `Co-Authored-By` line.

## Review Focus

- A test result that arrives after the key or base URL was edited, or after a newer test started → ignored; the status stays *not tested* or shows the newer result (Task 3).
- The key of the provider in use is removed while another provider has a key → the chat switches to that provider on *Save*; with no key anywhere it stays put and the panel shows *No API key set* (Task 3).
- A Keychain write fails during *Save* → `apply` throws, the provider in use is unchanged, the sheet stays open with the error (Task 4).
- A stored model that is not in the provider's cache, or a cache without a known default (data from the previous version) → the menu still shows one checked row (Task 2).
- A key that is only whitespace counts as no key; surrounding whitespace is trimmed before saving (Task 3).

---

### Task 1: Provider names and per-provider access in `ChatSession`

**Files:**
- Modify: `native/Sources/AtlasApp/ChatSession.swift`
- Test: `native/Tests/AtlasAppTests/ChatSessionTests.swift`

**Interfaces:**
- Produces, on `ChatSession`:
  - `func stored(_ provider: String) -> ChatSettings` — reads the session's own defaults.
  - `func models(for provider: String) -> [String]`
  - `func defaultModel(for provider: String) -> String?` — nil when not cached or empty.
  - `func cacheModels(_ list: [String], defaultModel: String? = nil, provider: String)` — replaces the existing two-argument method; writes `agent.<id>.defaultModel` when `defaultModel` is non-empty.
  - `func store(_ settings: ChatSettings)` — for the provider in use assigns `self.settings`; for any other provider writes only its `model` and `baseUrl` defaults.
  - `ChatSettings.providers` titles `DeepSeek`, `Claude`, `ChatGPT`.
- `cacheModels`, `store`, and `keyUpdated` call `objectWillChange.send()` when they change a provider that is not in use, so the menu re-renders.
- `reloadModels` passes the listing's `defaultModel` to `cacheModels`.

- [ ] **Step 1: Write the failing tests**

```swift
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

@Test func modelProvidersAreNamedAfterTheirProducts() {
    #expect(ChatSettings.providers.map(\.id) == ["deepseek", "anthropic", "openai"])
    #expect(ChatSettings.providers.map(\.title) == ["DeepSeek", "Claude", "ChatGPT"])
}
```

- [ ] **Step 2: Run them and see them fail to compile**

Run: `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-native-133 pnpm test:native`
Expected: build error naming `store`, `stored`, `models(for:)`.

- [ ] **Step 3: Implement the interfaces above in `ChatSession.swift`**

Keep `static func stored(_:_:)`; the instance method calls it with `defaults`.

- [ ] **Step 4: Run the tests**

Run: `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-native-133 pnpm test:native`
Expected: all pass, including the existing `chatModelListIsCachedPerProvider`.

- [ ] **Step 5: Commit** — `feat(chat): 会话按提供方读写模型设置与模型缓存 (#133)`

---

### Task 2: `ModelMenu` sections

**Files:**
- Create: `native/Sources/AtlasCore/ModelMenu.swift`
- Test: `native/Tests/AtlasCoreTests/ModelMenuTests.swift`

**Interfaces:**
- Produces (all `public`, `Equatable`, memberwise `public init`):

```swift
public struct ModelMenuProvider { public var id: String; public var title: String; public var hasKey: Bool
                                  public var models: [String]; public var defaultModel: String? }
public struct ModelMenuEntry {
    public var model: String      // "" for the default entry: choosing it stores an empty model
    public var title: String?     // the id to show; nil = the view shows L("Default model")
    public var isDefault: Bool
    public var selected: Bool
}
public struct ModelMenuSection { public var provider: String; public var title: String; public var needsKey: Bool
                                 public var entries: [ModelMenuEntry]; public var all: [ModelMenuEntry] }
public enum ModelMenu {
    public static let foldThreshold = 8
    public static func sections(providers: [ModelMenuProvider], provider: String, model: String) -> [ModelMenuSection]
    /// The model name for the menu button: `model`, or the provider's default when `model` is empty; nil = "Default model".
    public static func currentModel(providers: [ModelMenuProvider], provider: String, model: String) -> String?
}
```

- Rules for one provider (`inUse` = its id equals `provider`):
  - `hasKey == false` → `needsKey: true`, `entries` and `all` empty.
  - Default entry: `model: ""`, `title: defaultModel`, `isDefault: true`, `selected: inUse && (model.isEmpty || model == defaultModel)`.
  - `others` = `models` without `defaultModel` (unchanged when `defaultModel` is nil), each `selected: inUse && id == model`.
  - `custom` = one entry for `model` when `inUse`, `model` is non-empty, not the default, and not in `models`; `selected: true`.
  - `models.count <= foldThreshold` → `entries = [default] + custom + others`, `all = []`.
  - Otherwise → `entries = [default] + custom + the selected entry of others (if any)`, `all = others`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AtlasCore

private func provider(_ id: String, key: Bool = true, models: [String] = [], default defaultModel: String? = nil) -> ModelMenuProvider {
    ModelMenuProvider(id: id, title: id.uppercased(), hasKey: key, models: models, defaultModel: defaultModel)
}
private let many = (1...12).map { "m\($0)" }

@Test func modelMenuListsAShortCacheInFullWithTheDefaultFirst() {
    let section = ModelMenu.sections(providers: [provider("a", models: ["x", "d", "y"], default: "d")], provider: "a", model: "y")[0]
    #expect(section.entries.map(\.model) == ["", "x", "y"])
    #expect(section.entries.map(\.title) == ["d", "x", "y"])
    #expect(section.entries.map(\.selected) == [false, false, true])
    #expect(section.all.isEmpty && !section.needsKey)
}

@Test func modelMenuChecksTheDefaultForAnEmptyOrEqualModel() {
    let providers = [provider("a", models: ["d", "x"], default: "d")]
    #expect(ModelMenu.sections(providers: providers, provider: "a", model: "")[0].entries.map(\.selected) == [true, false])
    #expect(ModelMenu.sections(providers: providers, provider: "a", model: "d")[0].entries.map(\.selected) == [true, false])
}

@Test func modelMenuFoldsALongCacheIntoASubmenu() {
    let providers = [provider("a", models: many, default: "m1")]
    let idle = ModelMenu.sections(providers: providers, provider: "a", model: "")[0]
    #expect(idle.entries.map(\.model) == [""])
    #expect(idle.all.map(\.model) == Array(many.dropFirst()))
    let picked = ModelMenu.sections(providers: providers, provider: "a", model: "m7")[0]
    #expect(picked.entries.map(\.model) == ["", "m7"])
    #expect(picked.all.first { $0.selected }?.model == "m7")
    // Exactly at the threshold nothing folds.
    #expect(ModelMenu.sections(providers: [provider("a", models: Array(many.prefix(8)), default: "m1")], provider: "a", model: "")[0].all.isEmpty)
}

@Test func modelMenuKeepsAModelThatIsNotInTheCache() {
    let short = ModelMenu.sections(providers: [provider("a", models: ["d", "x"], default: "d")], provider: "a", model: "typed")[0]
    #expect(short.entries.map(\.model) == ["", "typed", "x"])
    #expect(short.entries.map(\.selected) == [false, true, false])
    let long = ModelMenu.sections(providers: [provider("a", models: many, default: "m1")], provider: "a", model: "typed")[0]
    #expect(long.entries.map(\.model) == ["", "typed"])
}

@Test func modelMenuWithoutAKnownDefaultShowsAGenericDefaultEntry() {
    let section = ModelMenu.sections(providers: [provider("a", models: ["d", "x"])], provider: "a", model: "")[0]
    #expect(section.entries.map(\.title) == [nil, "d", "x"])
    #expect(section.entries.map(\.selected) == [true, false, false])
}

@Test func modelMenuMarksOnlyTheProviderInUseAndAsksForMissingKeys() {
    let sections = ModelMenu.sections(providers: [provider("a", models: ["x"], default: "x"), provider("b", models: ["x"], default: "x"), provider("c", key: false, models: ["z"])],
                                      provider: "b", model: "")
    #expect(sections.map(\.provider) == ["a", "b", "c"])
    #expect(sections[0].entries.allSatisfy { !$0.selected })
    #expect(sections[1].entries.map(\.selected) == [true])
    #expect(sections[2].needsKey && sections[2].entries.isEmpty && sections[2].all.isEmpty)
}

@Test func modelMenuButtonNamesTheModelInUse() {
    let providers = [provider("a", models: ["d"], default: "d"), provider("b")]
    #expect(ModelMenu.currentModel(providers: providers, provider: "a", model: "x") == "x")
    #expect(ModelMenu.currentModel(providers: providers, provider: "a", model: "") == "d")
    #expect(ModelMenu.currentModel(providers: providers, provider: "b", model: "") == nil)
}
```

- [ ] **Step 2: Run and see the build fail on `ModelMenu`**

Run: `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-native-133 pnpm test:native`

- [ ] **Step 3: Implement `ModelMenu.swift` to the rules above**

- [ ] **Step 4: Run the tests** — expected: all pass.

- [ ] **Step 5: Commit** — `feat(chat): 模型菜单按提供方分组并折叠长列表的规则 (#133)`

---

### Task 3: `ModelSettingsDraft`

**Files:**
- Create: `native/Sources/AtlasCore/ModelSettingsDraft.swift`
- Test: `native/Tests/AtlasCoreTests/ModelSettingsDraftTests.swift`

**Interfaces:**
- Produces (all `public`, `Equatable`, memberwise `public init`):

```swift
public enum KeyTest: Equatable { case untested, testing, passed(models: Int), failed(String) }

public struct ProviderDraft {
    public var model: String
    public var baseUrl: String
    public var hasSavedKey: Bool
    public var newKey: String = ""       // as typed
    public var removesKey = false
    public var test: KeyTest = .untested
}

public struct ModelSettingsChanges {
    public var saveKeys: [String: String] = [:]                       // provider → trimmed key
    public var deleteKeys: [String] = []                              // in provider order
    public var settings: [String: ProviderSettingsChange] = [:]       // only providers whose model or base URL changed
    public var inUse: String
    public var isEmpty: Bool                                          // nothing to write and inUse unchanged
}
public struct ProviderSettingsChange { public var model: String; public var baseUrl: String } // trimmed

public struct ModelSettingsDraft {
    public init(order: [String], providers: [String: ProviderDraft], inUse: String)
    public let order: [String]
    public private(set) var providers: [String: ProviderDraft]
    public func hasKey(_ id: String) -> Bool        // (hasSavedKey && !removesKey) || a non-blank newKey
    public var inUse: String { get }                // what the chat will use after Save, automatic switch included
    public func canUse(_ id: String) -> Bool        // hasKey, test is not .failed, id != inUse
    public func canTest(_ id: String) -> Bool       // hasKey and test != .testing
    public mutating func use(_ id: String)          // no-op unless canUse
    public mutating func setKey(_ key: String, for id: String)       // clears removesKey; test → .untested
    public mutating func setBaseUrl(_ url: String, for id: String)   // test → .untested
    public mutating func setModel(_ model: String, for id: String)
    public mutating func removeKey(_ id: String)                     // newKey = "", removesKey = hasSavedKey; test → .untested
    public mutating func beginTest(_ id: String) -> Int?             // nil unless canTest; test → .testing; returns a token
    public mutating func finishTest(_ id: String, token: Int, result: KeyTest) // ignored unless token is the latest and test is still .testing
    public func changes() -> ModelSettingsChanges                    // against the state passed to init
}
```

- `inUse` rule: the explicitly chosen provider (initially the `inUse` passed to `init`, then the last successful `use`) when `hasKey` of it is true; otherwise the first id in `order` with `hasKey`; otherwise the chosen provider.
- `setKey`, `setBaseUrl`, and `removeKey` invalidate the outstanding token, so a result for the old value is dropped.
- `changes()`: `saveKeys` has an entry for every provider with a non-blank `newKey`; `deleteKeys` lists providers with `removesKey` and a blank `newKey`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AtlasCore

private func draft(inUse: String = "a", saved: Set<String> = ["a"]) -> ModelSettingsDraft {
    let ids = ["a", "b", "c"]
    return ModelSettingsDraft(order: ids, providers: Dictionary(uniqueKeysWithValues: ids.map {
        ($0, ProviderDraft(model: "", baseUrl: "", hasSavedKey: saved.contains($0)))
    }), inUse: inUse)
}

@Test func anUntouchedDraftChangesNothing() {
    #expect(draft().changes().isEmpty)
    #expect(draft().changes().inUse == "a")
}

@Test func addingAKeyToAnotherProviderLeavesTheOthersAlone() {
    var d = draft()
    d.setKey("  sk-new  ", for: "c")
    d.setModel(" gpt-x ", for: "c")
    let changes = d.changes()
    #expect(changes.saveKeys == ["c": "sk-new"])
    #expect(changes.deleteKeys.isEmpty)
    #expect(changes.settings == ["c": ProviderSettingsChange(model: "gpt-x", baseUrl: "")])
    #expect(changes.inUse == "a")
    #expect(d.canUse("c") && !d.canUse("a") && !d.canUse("b"))
    d.use("c")
    #expect(d.inUse == "c" && d.changes().inUse == "c")
}

@Test func aBlankKeyIsNoKey() {
    var d = draft()
    d.setKey("   \n", for: "b")
    #expect(!d.hasKey("b") && !d.canTest("b"))
    #expect(d.changes().saveKeys.isEmpty)
}

@Test func theChatMovesToAProviderWithAKeyWhenTheOneInUseHasNone() {
    var fresh = draft(inUse: "a", saved: [])
    #expect(fresh.inUse == "a") // No key anywhere: stay.
    fresh.setKey("sk-1", for: "c")
    #expect(fresh.inUse == "c")
    fresh.setKey("sk-2", for: "b")
    #expect(fresh.inUse == "b") // First in provider order.

    var removed = draft(inUse: "a", saved: ["a", "c"])
    removed.removeKey("a")
    #expect(removed.inUse == "c")
    #expect(removed.changes().deleteKeys == ["a"])
    removed.setKey("sk-again", for: "a") // Typing a key again cancels the removal and keeps the choice.
    #expect(removed.inUse == "a")
    #expect(removed.changes().deleteKeys.isEmpty && removed.changes().saveKeys == ["a": "sk-again"])
}

@Test func aFailedTestBlocksUsingTheProviderButNotSaving() {
    var d = draft()
    d.setKey("sk-bad", for: "b")
    let token = d.beginTest("b")!
    #expect(d.providers["b"]?.test == .testing && !d.canTest("b"))
    d.finishTest("b", token: token, result: .failed("Invalid API key"))
    #expect(!d.canUse("b"))
    #expect(d.changes().saveKeys == ["b": "sk-bad"])
}

@Test func aStaleTestResultIsIgnored() {
    var d = draft()
    d.setKey("sk-1", for: "b")
    let first = d.beginTest("b")!
    d.setKey("sk-2", for: "b") // Edited while the request is out.
    d.finishTest("b", token: first, result: .passed(models: 3))
    #expect(d.providers["b"]?.test == .untested)
    let second = d.beginTest("b")!
    d.finishTest("b", token: first, result: .failed("old"))
    #expect(d.providers["b"]?.test == .testing)
    d.finishTest("b", token: second, result: .passed(models: 3))
    #expect(d.providers["b"]?.test == .passed(models: 3))
    d.setBaseUrl("http://127.0.0.1:9", for: "b")
    #expect(d.providers["b"]?.test == .untested)
}

@Test func removingAKeyDisablesTestingUntilANewOneIsTyped() {
    var d = draft()
    d.removeKey("a")
    #expect(!d.hasKey("a") && !d.canTest("a") && d.beginTest("a") == nil)
    #expect(draft().canTest("a")) // A saved key can be tested without typing it.
}
```

- [ ] **Step 2: Run and see the build fail on `ModelSettingsDraft`**

- [ ] **Step 3: Implement `ModelSettingsDraft.swift` to the interface and rules above**

- [ ] **Step 4: Run the tests** — expected: all pass.

- [ ] **Step 5: Commit** — `feat(chat): 模型设置的未保存状态与保存规则 (#133)`

---

### Task 4: `ChatSession.apply` and the settings sheet

**Files:**
- Modify: `native/Sources/AtlasApp/ChatSession.swift`
- Modify: `native/Sources/AtlasApp/ChatPanel.swift` (replace `ChatSettingsSheet`, lines 292–469)
- Modify: the four `native/Sources/AtlasCore/Resources/*.lproj/Localizable.strings`
- Test: `native/Tests/AtlasAppTests/ChatSessionTests.swift`

**Interfaces:**
- Consumes: Task 1's per-provider methods; Task 3's `ModelSettingsDraft`, `ModelSettingsChanges`, `KeyTest`.
- Produces:
  - `ChatSession.init(defaults:readKey:writeKey:deleteKey:history:)` with `writeKey: @escaping (String, String) throws -> Void = { try Keychain.save($0, account: $1) }` (key, provider) and `deleteKey: @escaping (String) -> Void = Keychain.delete`.
  - `func draft() -> ModelSettingsDraft` — `order` from `ChatSettings.providers`, each provider's stored model, base URL, and key flag, `inUse: settings.provider`. Reads no Keychain.
  - `func apply(_ changes: ModelSettingsChanges) throws` — in this order: write every key in `saveKeys` (rethrowing the first failure before anything else is written for later providers), delete `deleteKeys`, call `keyUpdated` for each, `store` each changed provider's settings, then, if `changes.inUse != settings.provider`, assign `settings = stored(changes.inUse)`.
  - `ChatSettingsSheet(chat:root:runtime:provider:)` — `provider: String?` is the provider selected when the sheet opens; nil = the one in use.

- [ ] **Step 1: Write the failing tests**

```swift
@Test @MainActor func applyingSettingsWritesKeysAndLeavesOtherProvidersAlone() async throws {
    let defaults = UserDefaults(suiteName: "ui-atlas-chat-\(UUID().uuidString)")!
    var keychain = ["deepseek": "sk-deepseek-0000-1111"]
    let session = ChatSession(defaults: defaults, readKey: { keychain[$0] }, writeKey: { keychain[$1] = $0 }, deleteKey: { keychain[$0] = nil })
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
```

- [ ] **Step 2: Run and see them fail to compile**

- [ ] **Step 3: Implement `init`'s new parameters, `draft()`, and `apply(_:)`**

- [ ] **Step 4: Run the tests** — expected: all pass.

- [ ] **Step 5: Rewrite `ChatSettingsSheet`**

State: `@State draft: ModelSettingsDraft` (from `chat.draft()` on appear), `@State selected: String`, `@State replacingKey: Set<String>`, `@State error: String?`. Width 640.

- Left list, one row per `draft.order`: filled circle (`circle.fill`) when `draft.hasKey`, hollow (`circle`) otherwise; the title; a caption with the model (draft model, else `chat.defaultModel(for:)`, else *Default model*) or *No API key*; an *In use* tag when the id equals `draft.inUse`.
- Detail header: *In use*, or a *Use for Chat* button (`draft.use`) when `draft.canUse`, or the caption *Add an API key to use this provider*.
- *API key* row: masked `chat.keyHint(for:) ?? L("Saved")` with *Test*, *Replace*, *Remove* when the provider has a saved key that is neither being replaced nor removed and no new key is typed; otherwise a `SecureField` plus *Test*. *Test* is disabled unless `draft.canTest`, and reads *Testing…* while testing.
- *Base URL* and *Model* rows as today; the model menu beside the field lists `chat.models(for:)` with the default entry.
- Status line from `draft.providers[selected].test` and the spec's table; the failure message is the `ModelListError.message`.
- Running a test: `guard let token = draft.beginTest(id)`; key = the trimmed new key, or `chat.savedKeyValue(for: id)` when none was typed; call `ChatSession.listModels(root:runtime:settings:apiKey:)` with the draft base URL; on success `chat.cacheModels(list.models, defaultModel: list.defaultModel, provider: id)` and `finishTest(.passed(models: list.models.count))`; on failure `finishTest(.failed(message))`. With `root == nil` fail with the existing *Cannot find the ui-atlas source directory…* string.
- Leaving the key field with a non-blank new key runs the test. Nothing is fetched on appear or when `selected` changes.
- *Save*: `try chat.apply(draft.changes())` then dismiss; on error show `error.localizedDescription` and stay open. *Cancel* dismisses.
- Help text under the detail: per-provider storage and Keychain sentence; for `openai` add that an OpenAI API key is required and a ChatGPT subscription does not include one.

New strings (add all four tables; `%@` and `%d` as shown): `In use`, `No API key`, `Use for Chat`, `Add an API key to use this provider`, `Test`, `Testing…`, `Remove`, `Add an API key, then test it.`, `%d models available.`, `Test the key to load the available models.`, `The key works. %d models available.`, `The test failed: %@. You can still save.`, `Each provider keeps its own key, base URL, and model. Keys are stored only in this Mac’s keychain and are passed to the chat process through an environment variable; the UI shows only the first and last 4 characters.`, `ChatGPT needs an OpenAI API key; a ChatGPT subscription does not include one.` Remove the table entries that no call uses any more (`Delete Saved Key`, the old long help string, and the status strings the old sheet used), checking each with a search first.

- [ ] **Step 6: Build and run the tests**

Run: `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-native-133 pnpm test:native`
Expected: all pass, including `LocalizationTests`.

- [ ] **Step 7: Commit** — `feat(chat): 模型设置面板并列显示提供方并支持测试 key (#133)`

---

### Task 5: Model menu across providers

**Files:**
- Modify: `native/Sources/AtlasApp/ChatPanel.swift` (`modelMenu`, the `.sheet`, `missingKey`, the gear button)
- Modify: the four `Localizable.strings`

**Interfaces:**
- Consumes: `ModelMenu.sections`, `ModelMenu.currentModel`, `ChatSession.models(for:)`, `defaultModel(for:)`, `savedKey(for:)`, `stored(_:)`, `ChatSettingsSheet(chat:root:runtime:provider:)`.

- [ ] **Step 1: Replace the sheet trigger**

`showingSettings: Bool` becomes `@State private var settingsFor: SettingsTarget?` (a private `Identifiable` struct wrapping `provider: String?`), presented with `.sheet(item:)`. The gear button, *Model Settings…*, and *Set API Key…* open it with `provider: nil`.

- [ ] **Step 2: Rebuild `modelMenu` from sections**

- Build `[ModelMenuProvider]` from `ChatSettings.providers` with `chat.savedKey(for:)`, `chat.models(for:)`, `chat.defaultModel(for:)`; call `ModelMenu.sections(providers:provider:model:)` with `chat.settings`.
- Per section: `Section(title)`; for each entry a button labelled `entry.title ?? L("Default model")`, with a checkmark when `selected` and the suffix `L("Default")` shown for `isDefault` entries that have a title; when `all` is non-empty a nested `Menu(L("All %d Models", all.count))` with the same buttons; when `needsKey` a button `L("Add API Key…")` that sets `settingsFor` to that provider.
- Choosing an entry: `chat.settings = ChatSettings(provider: section.provider, model: entry.model, baseUrl: chat.stored(section.provider).baseUrl)`.
- Label: `"\(chat.settings.providerTitle) · \(ModelMenu.currentModel(…) ?? L("Default model"))"`.
- Keep *Reload Model List*, *Model Settings…*, and `.disabled(busy)`.

New strings: `Default`, `All %d Models`, `Add API Key…`.

- [ ] **Step 3: Run the tests**

Run: `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-native-133 pnpm test:native`
Expected: all pass.

- [ ] **Step 4: Commit** — `feat(chat): 模型菜单可在已配置的提供方之间切换 (#133)`

---

### Task 6: Docs, evidence, and the full gate

**Files:**
- Modify: `docs/macos.md` (Chat panel: *Input*, and a new *Model settings* bullet), `GLOSSARY.md` (*Model provider*), `README.md` (lines naming the providers and the provider table's first column), the spec's *Tracking* and *Status* lines
- Create: `docs/evidence/133-model-settings-light.png`, `-dark.png`, `133-model-settings-test-failed-light.png`, `-dark.png`, `133-model-menu-light.png`, `-dark.png`

- [ ] **Step 1: Update the docs** to the shipped behaviour and the names DeepSeek, Claude, ChatGPT. In `README.md` keep the API column (`OpenAI-compatible`, `Messages API`, `Responses API`) as it is.

- [ ] **Step 2: Run the full gate**

Run: `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-native-133 pnpm test:native` and `pnpm check`
Expected: both pass.

- [ ] **Step 3: Check the real app in light and dark appearance**

Run `pnpm dev`. To exercise *Test* without a real key, serve a model list locally (any key is accepted) and enter its address as the base URL:

```bash
node -e "require('http').createServer((q,s)=>{s.setHeader('content-type','application/json');s.end(JSON.stringify({data:Array.from({length:12},(_,i)=>({id:'model-'+(i+1)}))}))}).listen(8787)"
```

- Base URL `http://127.0.0.1:8787` + any key → *The key works. 12 models available.*; after *Save* the model menu folds that provider into *All 12 Models*.
- Base URL `http://127.0.0.1:9` → the failure line; *Use for Chat* disappears; *Save* still works.
- Remove a key, press *Cancel*, reopen → the key is still there.
- Capture the six screenshots listed above.

- [ ] **Step 4: Commit** — `docs(chat): 更新模型设置说明并补充界面证据 (#133)`

- [ ] **Step 5: Hand off to delivery** — push, open the PR against `main` with `Closes #133`, and note that acceptance against real provider keys is left to the user.
