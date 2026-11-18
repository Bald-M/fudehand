import Testing
@testable import FudehandCore

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

@Test func clearingATypedKeyKeepsTheRemoval() {
    var d = draft()
    d.removeKey("a")
    d.setKey("x", for: "a")
    d.setKey("", for: "a")
    #expect(!d.hasKey("a"))
    #expect(d.changes().deleteKeys == ["a"] && d.changes().saveKeys.isEmpty)
}

@Test func aBlankKeyOnASavedKeyKeepsTheSavedKey() {
    var d = draft()
    d.setKey("   ", for: "a")
    #expect(d.hasKey("a"))
    #expect(d.changes().saveKeys.isEmpty && d.changes().deleteKeys.isEmpty)
}

@Test func losingTheChosenProvidersKeyFallsBackToTheOriginalProvider() {
    var d = draft(inUse: "c", saved: ["a", "c"])
    d.setKey("sk-b", for: "b")
    d.use("b")
    #expect(d.inUse == "b")
    d.setKey("", for: "b")
    #expect(d.inUse == "c")
}
