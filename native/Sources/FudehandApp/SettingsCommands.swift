import FudehandCore
import Foundation

/// The `settings_*` tools: they change the same state the menus, the Model Settings sheet, and the MCP Connectors window change,
/// through the same methods. Settings are not undoable, so every change returns the previous values. API keys are write-only:
/// nothing here returns one, only whether one is saved and its masked hint.
extension FudehandStore {
    func handleSettings(_ command: ControlCommand) async throws -> Any {
        switch command {
        case .getInterface:
            return interfaceSettings()
        case .updateInterface(let language, let appearance):
            let previous = interfaceSettings()
            if let appearance { theme = appearance.rawValue }
            var result = interfaceSettings()
            if let language, language != self.language {
                self.language = language
                result = interfaceSettings()
                result["note"] = "Menu items that macOS provides change language after Fudehand restarts."
            }
            result["previous"] = previous
            return result
        case .getModels:
            return modelSettings()
        case .updateModelProvider(let id, let model, let baseUrl, let use):
            try requireProvider(id)
            var draft = chat.draft()
            if use, id != draft.inUse, !draft.canUse(id) {
                throw ControlCommandError("\(providerTitle(id)) has no API key; save one with settings_set_api_key first")
            }
            let previous = providerSettings(id)
            if let model { draft.setModel(model, for: id) }
            if let baseUrl { draft.setBaseUrl(baseUrl, for: id) }
            if use { draft.use(id) }
            try applyModelSettings(draft)
            return ["provider": providerSettings(id), "previous": previous, "note": nextMessageNote]
        case .listModels(let id, let baseUrl):
            try requireProvider(id)
            guard let root = toolsRoot else { throw ControlCommandError("Cannot find the Fudehand source directory, so the model list is unavailable") }
            guard let key = chat.savedKeyValue(for: id) else { throw ControlCommandError("No API key is saved for \(providerTitle(id)); save one with settings_set_api_key first") }
            let settings = ChatSettings(provider: id, model: "", baseUrl: (baseUrl ?? chat.stored(id).baseUrl).trimmingCharacters(in: .whitespacesAndNewlines))
            let previous: [String: Any] = ["models": chat.models(for: id), "defaultModel": chat.defaultModel(for: id) ?? NSNull()]
            switch await ChatSession.listModels(root: root, runtime: runtime, settings: settings, apiKey: key) {
            case .success(let list):
                chat.cacheModels(list.models, defaultModel: list.defaultModel, windows: list.windows, provider: id)
                return ["provider": id, "models": list.models, "defaultModel": chat.defaultModel(for: id) ?? NSNull(), "previous": previous]
            case .failure(let failure):
                // The harness strips the key from its messages; this is a second guard.
                throw ControlCommandError("Could not list \(providerTitle(id)) models: \(failure.english.replacingOccurrences(of: key, with: "***"))")
            }
        case .setAPIKey(let id, let key):
            try requireProvider(id)
            let previous = keySettings(id)
            var draft = chat.draft()
            draft.setKey(key, for: id)
            try applyModelSettings(draft)
            return ["provider": providerSettings(id), "previous": previous, "note": nextMessageNote]
        case .deleteAPIKey(let id):
            try requireProvider(id)
            guard chat.savedKey(for: id) else { throw ControlCommandError("No API key is saved for \(providerTitle(id))") }
            let previous = keySettings(id)
            var draft = chat.draft()
            draft.removeKey(id)
            try applyModelSettings(draft)
            return ["provider": providerSettings(id), "previous": previous, "inUse": chat.settings.provider, "note": nextMessageNote]
        case .getConnectors:
            await connectors.refresh()
            return ["connectors": AgentConnector.allCases.map(connectorState)]
        case .setConnector(let connector, let connected):
            await connectors.refresh()
            let previous = connectorState(connector)
            let outcome = connected ? await connectors.connect(connector) : await connectors.disconnect(connector)
            if let error = outcome.error { throw ControlCommandError(error) }
            var result: [String: Any] = ["connector": connectorState(connector), "previous": previous,
                                         "note": "\(connector.title) picks the change up in new sessions."]
            if let command = outcome.command { result["command"] = command }
            if let file = outcome.file { result["file"] = file }
            return result
        default:
            throw ControlCommandError("Not a settings command")
        }
    }

    private var nextMessageNote: String { "Applies from the next message; a reply already running keeps its model and key." }

    private func interfaceSettings() -> [String: Any] {
        ["language": language.rawValue, "appearance": theme,
         "languages": AppLanguage.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
         "appearances": Appearance.allCases.map(\.rawValue)]
    }

    private func requireProvider(_ id: String) throws {
        guard ChatSettings.providers.contains(where: { $0.id == id }) else {
            throw ControlCommandError("provider must be one of \(ChatSettings.providers.map(\.id).joined(separator: ", ")); got \(id)")
        }
    }

    private func providerTitle(_ id: String) -> String { ChatSettings.providers.first { $0.id == id }?.title ?? id }

    /// Writes the draft the way the Model Settings sheet's Save does.
    private func applyModelSettings(_ draft: ModelSettingsDraft) throws {
        do { try chat.apply(draft.changes()) } catch let error as KeychainError {
            throw ControlCommandError("Cannot save to the keychain (\(error.status))")
        }
    }

    private func keySettings(_ id: String) -> [String: Any] {
        ["hasKey": chat.savedKey(for: id), "keyHint": chat.keyHint(for: id) ?? NSNull()]
    }

    /// One provider as the settings sheet shows it; the provider in use shows the selected conversation's model.
    private func providerSettings(_ id: String) -> [String: Any] {
        let settings = chat.draft().providers[id]
        return ["id": id, "title": providerTitle(id), "inUse": chat.settings.provider == id,
                "model": settings?.model ?? "", "baseUrl": settings?.baseUrl ?? "",
                "hasKey": chat.savedKey(for: id), "keyHint": chat.keyHint(for: id) ?? NSNull(),
                "models": chat.models(for: id), "defaultModel": chat.defaultModel(for: id) ?? NSNull()]
    }

    private func modelSettings() -> [String: Any] {
        ["inUse": chat.settings.provider, "providers": ChatSettings.providers.map { providerSettings($0.id) }]
    }

    private func connectorState(_ connector: AgentConnector) -> [String: Any] {
        let entry = connectors.entries[connector]
        var state: [String: Any] = ["id": connector.rawValue, "title": connector.title]
        switch entry?.status {
        case nil: state["status"] = "checking"
        case .unavailable: state["status"] = "unavailable"
        case .disconnected: state["status"] = "disconnected"
        case .connected: state["status"] = "connected"
        case .elsewhere(let command): state["status"] = "elsewhere"; state["registeredCommand"] = command
        }
        if let error = entry?.englishError { state["error"] = error }
        return state
    }
}
