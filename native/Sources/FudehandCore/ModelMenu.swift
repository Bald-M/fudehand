/// One provider as the chat panel's model menu sees it: whether its API key is stored, its cached model ids, and the model it uses when none is chosen.
public struct ModelMenuProvider: Equatable, Sendable {
    public var id: String
    public var title: String
    public var hasKey: Bool
    public var models: [String]
    public var defaultModel: String?

    public init(id: String, title: String, hasKey: Bool, models: [String], defaultModel: String?) {
        self.id = id
        self.title = title
        self.hasKey = hasKey
        self.models = models
        self.defaultModel = defaultModel
    }
}

public struct ModelMenuEntry: Equatable, Sendable {
    /// "" for the default entry: choosing it stores an empty model.
    public var model: String
    /// The id to show; nil means the view shows the localized "Default model".
    public var title: String?
    public var isDefault: Bool
    public var selected: Bool

    public init(model: String, title: String?, isDefault: Bool, selected: Bool) {
        self.model = model
        self.title = title
        self.isDefault = isDefault
        self.selected = selected
    }
}

public struct ModelMenuSection: Equatable, Sendable {
    public var provider: String
    public var title: String
    /// The provider has no stored key, so it lists no models and the view offers to set one up.
    public var needsKey: Bool
    /// Shown directly in the menu.
    public var entries: [ModelMenuEntry]
    /// Every cached model, shown in a submenu; empty unless the cache is longer than `foldThreshold`.
    public var all: [ModelMenuEntry]

    public init(provider: String, title: String, needsKey: Bool, entries: [ModelMenuEntry], all: [ModelMenuEntry]) {
        self.provider = provider
        self.title = title
        self.needsKey = needsKey
        self.entries = entries
        self.all = all
    }
}

/// Turns the providers, their cached model lists and the current selection into the chat panel's model menu sections.
public enum ModelMenu {
    /// A cache longer than this folds into a submenu.
    public static let foldThreshold = 8

    public static func sections(providers: [ModelMenuProvider], provider: String, model: String) -> [ModelMenuSection] {
        providers.map { item in
            guard item.hasKey else { return ModelMenuSection(provider: item.id, title: item.title, needsKey: true, entries: [], all: []) }
            let inUse = item.id == provider
            let defaultEntry = ModelMenuEntry(model: "", title: item.defaultModel, isDefault: true,
                                              selected: inUse && (model.isEmpty || model == item.defaultModel))
            let others = item.models.filter { $0 != item.defaultModel }.map {
                ModelMenuEntry(model: $0, title: $0, isDefault: false, selected: inUse && $0 == model)
            }
            var head = [defaultEntry]
            if inUse, !model.isEmpty, model != item.defaultModel, !item.models.contains(model) {
                head.append(ModelMenuEntry(model: model, title: model, isDefault: false, selected: true))
            }
            if item.models.count <= foldThreshold {
                return ModelMenuSection(provider: item.id, title: item.title, needsKey: false, entries: head + others, all: [])
            }
            let all = item.models.map { ModelMenuEntry(model: $0, title: $0, isDefault: false, selected: inUse && $0 == model) }
            return ModelMenuSection(provider: item.id, title: item.title, needsKey: false, entries: head + others.filter(\.selected), all: all)
        }
    }

    /// The model name for the menu button: `model`, or the provider's default when `model` is empty; nil means "Default model".
    public static func currentModel(providers: [ModelMenuProvider], provider: String, model: String) -> String? {
        model.isEmpty ? providers.first { $0.id == provider }?.defaultModel : model
    }
}

/// One model of one provider, for a flat list such as the one the `/model` command shows.
public struct ModelChoice: Equatable, Sendable {
    public var provider: String
    public var providerTitle: String
    /// "" for the provider's default model.
    public var model: String
    /// The id to show; nil means the view shows the localized "Default model".
    public var title: String?
    public var isDefault: Bool
    public var selected: Bool
}

extension ModelMenu {
    /// Every model the menu offers, across the providers that have a key, narrowed to those whose model or provider name contains `query`.
    public static func choices(providers: [ModelMenuProvider], provider: String, model: String, matching query: String) -> [ModelChoice] {
        let query = query.lowercased()
        return sections(providers: providers, provider: provider, model: model).flatMap { section in
            // A folded section repeats the default and the selected model in `all`.
            let head = section.entries.filter { entry in entry.isDefault || !section.all.contains { $0.model == entry.model } }
            let rest = section.all.filter { entry in !head.contains { $0.isDefault && $0.title == entry.model } }
            return (head + rest).map {
                ModelChoice(provider: section.provider, providerTitle: section.title, model: $0.model, title: $0.title, isDefault: $0.isDefault, selected: $0.selected)
            }
        }.filter { query.isEmpty || ($0.title ?? "").lowercased().contains(query) || $0.providerTitle.lowercased().contains(query) }
    }
}
