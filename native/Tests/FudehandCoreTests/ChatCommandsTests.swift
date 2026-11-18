import Testing
@testable import FudehandCore

@Test func aDraftThatDoesNotStartWithASlashIsAMessage() {
    #expect(ChatCommandInput("") == .message)
    #expect(ChatCommandInput("Make it blue") == .message)
    #expect(ChatCommandInput(" /plan") == .message)
    #expect(ChatCommandInput("Use a/b testing") == .message)
}

@Test func typingACommandNameListsTheCommandsItStarts() {
    #expect(ChatCommandInput("/") == .typing(ChatCommand.allCases))
    #expect(ChatCommand.allCases.map(\.name) == ["/plan", "/goal", "/new", "/clear", "/compact", "/model"])
    #expect(ChatCommandInput("/pl") == .typing([.plan]))
    #expect(ChatCommandInput("/PL") == .typing([.plan]))
    #expect(ChatCommandInput("/plan") == .typing([.plan]))
    #expect(ChatCommandInput("/x") == .typing([]))
}

@Test func aCommandNameFollowedByTextIsThatCommandWithItsArgument() {
    #expect(ChatCommandInput("/plan  a login screen ") == .command(.plan, argument: "a login screen"))
    #expect(ChatCommandInput("/goal\nfinish the page") == .command(.goal, argument: "finish the page"))
    #expect(ChatCommandInput("/model ") == .command(.model, argument: ""))
    #expect(ChatCommandInput("/pl a login screen") == .unknown("/pl"))
    #expect(ChatCommandInput("/Users/me/a.png here") == .unknown("/Users/me/a.png"))
}

@Test func onlyPlanAndGoalSwitchTheMode() {
    #expect(ChatCommand.allCases.map(\.mode) == [.plan, .goal, nil, nil, nil, nil])
}

private func provider(_ id: String, key: Bool = true, models: [String] = [], default defaultModel: String? = nil) -> ModelMenuProvider {
    ModelMenuProvider(id: id, title: id.uppercased(), hasKey: key, models: models, defaultModel: defaultModel)
}

@Test func modelChoicesListEveryModelOfTheProvidersWithAKey() {
    let providers = [provider("a", models: (1...12).map { "m\($0)" }, default: "m1"), provider("b", key: false, models: ["x"]), provider("c", models: ["x", "y"], default: nil)]
    let all = ModelMenu.choices(providers: providers, provider: "a", model: "m3", matching: "")
    #expect(all.map(\.provider) == Array(repeating: "a", count: 12) + ["c", "c", "c"])
    #expect(all.map(\.model) == [""] + (2...12).map { "m\($0)" } + ["", "x", "y"])
    #expect(all.filter(\.selected).map(\.model) == ["m3"])
    #expect(all[0].title == "m1" && all[0].isDefault && all[12].title == nil)
}

@Test func modelChoicesAreNarrowedByModelOrProviderName() {
    let providers = [provider("a", models: ["chat", "reasoner"], default: "chat"), provider("c", models: ["opus"], default: "opus")]
    #expect(ModelMenu.choices(providers: providers, provider: "a", model: "", matching: "REAS").map(\.model) == ["reasoner"])
    #expect(ModelMenu.choices(providers: providers, provider: "a", model: "", matching: "c").map(\.model) == ["", ""])
    #expect(ModelMenu.choices(providers: providers, provider: "a", model: "", matching: "zzz").isEmpty)
}
