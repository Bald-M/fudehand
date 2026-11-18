import Foundation

/// The outcome of testing a provider's key against its endpoint.
public enum KeyTest: Equatable, Sendable { case untested, testing, passed(models: Int), failed(String) }

/// One provider's unsaved state in the model settings sheet.
public struct ProviderDraft: Equatable, Sendable {
    public var model: String
    public var baseUrl: String
    /// A key is already stored in the Keychain.
    public var hasSavedKey: Bool
    /// The key as typed, untrimmed.
    public var newKey: String
    public var removesKey: Bool
    public var test: KeyTest

    public init(model: String, baseUrl: String, hasSavedKey: Bool, newKey: String = "", removesKey: Bool = false, test: KeyTest = .untested) {
        self.model = model
        self.baseUrl = baseUrl
        self.hasSavedKey = hasSavedKey
        self.newKey = newKey
        self.removesKey = removesKey
        self.test = test
    }
}

public struct ProviderSettingsChange: Equatable, Sendable {
    /// Both trimmed.
    public var model: String
    public var baseUrl: String

    public init(model: String, baseUrl: String) {
        self.model = model
        self.baseUrl = baseUrl
    }
}

/// What Save must write.
public struct ModelSettingsChanges: Equatable, Sendable {
    /// Provider → trimmed key.
    public var saveKeys: [String: String]
    /// In provider order.
    public var deleteKeys: [String]
    /// Only providers whose model or base URL changed.
    public var settings: [String: ProviderSettingsChange]
    public var inUse: String
    /// Nothing to write and the provider in use is unchanged.
    public var isEmpty: Bool

    public init(saveKeys: [String: String] = [:], deleteKeys: [String] = [], settings: [String: ProviderSettingsChange] = [:], inUse: String, isEmpty: Bool) {
        self.saveKeys = saveKeys
        self.deleteKeys = deleteKeys
        self.settings = settings
        self.inUse = inUse
        self.isEmpty = isEmpty
    }
}

/// The model settings sheet's unsaved state: every edit stays here until Save, and `changes()` says what Save writes.
public struct ModelSettingsDraft: Equatable, Sendable {
    public let order: [String]
    public private(set) var providers: [String: ProviderDraft]
    private let initial: [String: ProviderDraft]
    private let initialInUse: String
    /// The provider picked explicitly; `inUse` falls back from it when it has no key.
    private var chosen: String
    private var tokens: [String: Int] = [:]
    private var lastToken = 0

    public init(order: [String], providers: [String: ProviderDraft], inUse: String) {
        self.order = order
        self.providers = providers
        initial = providers
        initialInUse = inUse
        chosen = inUse
    }

    public func hasKey(_ id: String) -> Bool {
        guard let p = providers[id] else { return false }
        return (p.hasSavedKey && !p.removesKey) || !Self.trimmed(p.newKey).isEmpty
    }

    /// What the chat will use after Save, including the automatic switch to a provider with a key.
    public var inUse: String {
        if hasKey(chosen) { return chosen }
        return order.first(where: hasKey) ?? chosen
    }

    public func canUse(_ id: String) -> Bool {
        guard hasKey(id), id != inUse else { return false }
        if case .failed = providers[id]?.test { return false }
        return true
    }

    public func canTest(_ id: String) -> Bool { hasKey(id) && providers[id]?.test != .testing }

    public mutating func use(_ id: String) { if canUse(id) { chosen = id } }

    public mutating func setKey(_ key: String, for id: String) {
        guard providers[id] != nil else { return }
        providers[id]?.newKey = key
        providers[id]?.removesKey = false
        invalidateTest(id)
    }

    public mutating func setBaseUrl(_ url: String, for id: String) {
        guard providers[id] != nil else { return }
        providers[id]?.baseUrl = url
        invalidateTest(id)
    }

    public mutating func setModel(_ model: String, for id: String) { providers[id]?.model = model }

    public mutating func removeKey(_ id: String) {
        guard let p = providers[id] else { return }
        providers[id]?.newKey = ""
        providers[id]?.removesKey = p.hasSavedKey
        invalidateTest(id)
    }

    /// Starts a test and returns its token, or nil when the provider cannot be tested.
    public mutating func beginTest(_ id: String) -> Int? {
        guard canTest(id) else { return nil }
        lastToken += 1
        tokens[id] = lastToken
        providers[id]?.test = .testing
        return lastToken
    }

    public mutating func finishTest(_ id: String, token: Int, result: KeyTest) {
        guard tokens[id] == token, providers[id]?.test == .testing else { return }
        providers[id]?.test = result
    }

    public func changes() -> ModelSettingsChanges {
        var saveKeys: [String: String] = [:], deleteKeys: [String] = [], settings: [String: ProviderSettingsChange] = [:]
        for id in order {
            guard let p = providers[id] else { continue }
            let key = Self.trimmed(p.newKey)
            if !key.isEmpty { saveKeys[id] = key } else if p.removesKey { deleteKeys.append(id) }
            let now = ProviderSettingsChange(model: Self.trimmed(p.model), baseUrl: Self.trimmed(p.baseUrl))
            let before = initial[id].map { ProviderSettingsChange(model: Self.trimmed($0.model), baseUrl: Self.trimmed($0.baseUrl)) }
            if now != before { settings[id] = now }
        }
        let use = inUse
        return ModelSettingsChanges(saveKeys: saveKeys, deleteKeys: deleteKeys, settings: settings, inUse: use,
                                    isEmpty: saveKeys.isEmpty && deleteKeys.isEmpty && settings.isEmpty && use == initialInUse)
    }

    /// An edit makes any outstanding or finished test result stale.
    private mutating func invalidateTest(_ id: String) {
        tokens[id] = nil
        providers[id]?.test = .untested
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
