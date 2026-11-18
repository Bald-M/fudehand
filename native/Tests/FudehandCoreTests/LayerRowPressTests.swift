import Testing
@testable import FudehandCore

@Test func plainPressOnALayerRowSelectsOnlyThatLayer() {
    #expect(LayerRowPress.resolve(id: "b", selection: ["a"], clickCount: 1) == .select(["b"]))
}

@Test func commandPressTogglesTheLayerInTheSelection() {
    #expect(LayerRowPress.resolve(id: "b", selection: ["a"], clickCount: 1, command: true) == .select(["a", "b"]))
    #expect(LayerRowPress.resolve(id: "b", selection: ["a", "b"], clickCount: 1, command: true) == .select(["a"]))
}

@Test func shiftPressAddsTheLayerToTheSelection() {
    #expect(LayerRowPress.resolve(id: "b", selection: ["a"], clickCount: 1, shift: true) == .select(["a", "b"]))
    #expect(LayerRowPress.resolve(id: "a", selection: ["a"], clickCount: 1, shift: true) == .select(["a"]))
}

@Test func secondPressOfADoubleClickRenamesInsteadOfSelecting() {
    #expect(LayerRowPress.resolve(id: "b", selection: ["b"], clickCount: 2) == .rename)
}

@Test func doubleClickWithAModifierKeepsEditingTheSelection() {
    #expect(LayerRowPress.resolve(id: "b", selection: ["a"], clickCount: 2, command: true) == .select(["a", "b"]))
}
