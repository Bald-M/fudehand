import Testing
@testable import FudehandCore

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
    #expect(idle.all.map(\.model) == many)
    let stored = ModelMenu.sections(providers: providers, provider: "a", model: "m1")[0]
    #expect(stored.entries.first?.selected == true)
    #expect(stored.all.first { $0.selected }?.model == "m1")
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
