import Foundation
import Testing
@testable import FudehandCore

@Suite struct ComponentSyncTests {
    private static let red = DesignColor(r: 1, g: 0, b: 0)
    private static let blue = DesignColor(r: 0, g: 0, b: 1)
    private static let green = DesignColor(r: 0, g: 1, b: 0)

    /// Main component `m` (a frame with text child `t`) and an instance `i` of it at x 300.
    private func componentFixture() -> DesignDocument {
        var main = DesignNode(id: "m", type: .frame, name: "Button", width: 200, height: 60)
        main.component = true
        main.fill = Self.red
        var label = DesignNode(id: "t", type: .text, name: "Label", x: 16, y: 20, width: 100, height: 20)
        label.text = DesignText(content: "OK")
        main.children = [label]
        var existing: Set<String> = ["m", "t", "i"]
        var instance = ComponentSync.makeInstance(of: main, existing: &existing)
        instance.id = "i"
        instance.x = 300
        return DesignDocument(nodes: [main, instance])
    }

    /// Applies `change` to `document`, then reconciles it against the document before the change.
    private func edit(_ document: DesignDocument, _ change: (inout DesignDocument) -> Void) -> DesignDocument {
        var next = document
        change(&next)
        ComponentSync.reconcile(old: document, new: &next)
        return next
    }

    private func instance(_ document: DesignDocument) -> DesignNode { document.node("i")! }

    @Test func makeInstanceMirrorsComponent() {
        let document = componentFixture()
        let main = document.node("m")!
        let root = instance(document)
        #expect(root.instance == "m")
        #expect(root.source == "m")
        #expect(!root.component)
        #expect(root.overrides.isEmpty)
        #expect(ComponentProperty.changed(main, root) == ["x"])
        let child = root.children[0]
        #expect(child.id != "t")
        #expect(child.source == "t")
        #expect(child.instance == nil)
        #expect(ComponentProperty.changed(main.children[0], child).isEmpty)
        #expect(Set(document.allIDs()).count == document.nodeCount)
    }

    @Test func fillChangePropagates() {
        let document = edit(componentFixture()) { $0.update(at: [0]) { $0.fill = Self.blue } }
        #expect(instance(document).fill == Self.blue)
        #expect(instance(document).overrides.isEmpty)
    }

    @Test func textContentOverrideSurvives() {
        var document = edit(componentFixture()) { $0.update(at: [1, 0]) { $0.text?.content = "Go" } }
        #expect(instance(document).children[0].overrides == ["text.content"])
        document = edit(document) {
            $0.update(at: [0, 0]) { $0.text?.content = "Yes"; $0.text?.color = Self.green }
        }
        let label = instance(document).children[0]
        #expect(label.text?.content == "Go")
        #expect(label.text?.color == Self.green)
        #expect(label.overrides == ["text.content"])
    }

    @Test func editEqualToMainRemovesOverride() {
        var document = edit(componentFixture()) { $0.update(at: [1, 0]) { $0.text?.content = "Go" } }
        document = edit(document) { $0.update(at: [1, 0]) { $0.text?.content = "OK" } }
        #expect(instance(document).children[0].overrides.isEmpty)
        #expect(instance(document).children[0].text?.content == "OK")
    }

    @Test func rootPositionNeverSyncedOrOverridden() {
        var document = edit(componentFixture()) { $0.update(at: [1]) { $0.x = 500; $0.y = 40 } }
        #expect(instance(document).overrides.isEmpty)
        document = edit(document) { $0.update(at: [0]) { $0.x = 50; $0.y = 70; $0.fill = Self.blue } }
        let root = instance(document)
        #expect(root.x == 500 && root.y == 40)
        #expect(root.fill == Self.blue)
        #expect(root.overrides.isEmpty)
    }

    @Test func childAddedRemovedReordered() {
        let before = componentFixture()
        var document = edit(before) {
            $0.update(at: [0]) { $0.children.insert(DesignNode(id: "a", type: .rectangle), at: 0) }
        }
        var root = instance(document)
        #expect(root.children.map(\.source) == ["a", "t"])
        let added = root.children[0]
        #expect(added.id != "a" && !before.allIDs().contains(added.id))
        let labelID = root.children[1].id
        #expect(labelID == instance(before).children[0].id)

        document = edit(document) { $0.update(at: [0]) { $0.children.reverse() } }
        root = instance(document)
        #expect(root.children.map(\.source) == ["t", "a"])
        #expect(root.children.map(\.id) == [labelID, added.id])

        document = edit(document) { $0.update(at: [0]) { $0.children.removeAll { $0.id == "t" } } }
        root = instance(document)
        #expect(root.children.map(\.id) == [added.id])
        #expect(Set(document.allIDs()).count == document.nodeCount)
    }

    @Test func replaceColorEverywhereLeavesInstancesFollowing() {
        var document = edit(componentFixture()) {
            $0.update(at: [0]) { $0.fill = Self.blue }
            $0.update(at: [1]) { $0.fill = Self.blue }
        }
        #expect(instance(document).overrides.isEmpty)
        document = edit(document) { $0.update(at: [0]) { $0.fill = Self.green } }
        #expect(instance(document).fill == Self.green)
    }

    @Test func unchangedDocumentIsReturnedAsIs() {
        var frame = DesignNode(id: "f", type: .frame)
        frame.children = [DesignNode(id: "r", type: .rectangle)]
        let document = DesignDocument(nodes: [frame, DesignNode(id: "g", type: .rectangle)])
        let counter = ComponentSync.SyncCounter()
        ComponentSync.$syncCount.withValue(counter) {
            var next = document
            next.update(at: [0, 0]) { $0.fill = Self.blue }
            let changed = next.nodes
            let storage = (Self.storage(next.nodes), Self.storage(next.nodes[0].children))
            ComponentSync.reconcile(old: document, new: &next)
            #expect(next.nodes == changed)
            // No mutable access: the changed path's arrays were not copied.
            #expect(Self.storage(next.nodes) == storage.0)
            #expect(Self.storage(next.nodes[0].children) == storage.1)

            var same = document
            ComponentSync.reconcile(old: document, new: &same)
            #expect(same == document)
        }
        #expect(counter.count == 0)
    }

    private static func storage(_ nodes: [DesignNode]) -> UnsafeRawPointer? {
        nodes.withUnsafeBufferPointer { $0.baseAddress.map(UnsafeRawPointer.init) }
    }

    @Test func mainChildMovePropagates() {
        let document = edit(componentFixture()) { $0.update(at: [0, 0]) { $0.x = 40 } }
        let root = instance(document)
        #expect(root.children[0].x == 40)
        #expect(root.children[0].overrides.isEmpty && root.overrides.isEmpty)
        #expect(root.x == 300)
    }

    @Test func instanceChildMoveBecomesOverride() {
        var document = edit(componentFixture()) { $0.update(at: [1, 0]) { $0.x = 40 } }
        #expect(instance(document).children[0].overrides == ["x"])
        document = edit(document) { $0.update(at: [0, 0]) { $0.y = 33 } }
        let label = instance(document).children[0]
        #expect(label.x == 40 && label.y == 33)
        #expect(label.overrides == ["x"])
    }

    @Test func resetWholeObjectAndFieldOverrides() throws {
        let document = edit(componentFixture()) {
            $0.update(at: [1, 0]) { $0.text?.content = "Go"; $0.text?.color = Self.green }
        }
        let main = try #require(document.node("m"))
        var label = instance(document).children[0]
        ComponentSync.resetOverrides(&label, component: main, properties: ["text"])
        #expect(label.overrides.isEmpty)
        #expect(label.text == main.children[0].text)

        // A whole-object override: resetting one field keeps the other differing fields as field overrides.
        label.text?.content = "Go"
        label.text?.color = Self.green
        label.overrides = ["text"]
        ComponentSync.resetOverrides(&label, component: main, properties: ["text.color"])
        #expect(label.overrides == ["text.content"])
        #expect(label.text?.content == "Go")
        #expect(label.text?.color == main.children[0].text?.color)
    }

    @Test func unrelatedEditDoesNotSyncInstances() {
        var document = componentFixture()
        document.nodes.append(DesignNode(id: "x", type: .rectangle))
        let counter = ComponentSync.SyncCounter()
        ComponentSync.$syncCount.withValue(counter) {
            _ = edit(document) { $0.update(at: [2]) { $0.fill = Self.blue } }
            _ = edit(document) { $0.update(at: [1]) { $0.x = 900 } }
        }
        #expect(counter.count == 0)
    }

    @Test func missingMainComponentLeavesInstanceUntouched() {
        var cut = componentFixture()
        cut.nodes.remove(at: 0)
        let document = edit(cut) { $0.update(at: [0, 0]) { $0.text?.content = "Go" } }
        #expect(document.node("i")!.children[0].text?.content == "Go")
        #expect(document.node("i")!.children[0].overrides.isEmpty)
        #expect(document.node("i")!.instance == "m")
    }

    @Test func resetOverridesRestoresMainValues() throws {
        var document = edit(componentFixture()) {
            $0.update(at: [1]) { $0.fill = Self.blue; $0.x = 420 }
            $0.update(at: [1, 0]) { $0.text?.content = "Go"; $0.text?.color = Self.green }
        }
        let main = try #require(document.node("m"))
        var root = instance(document)
        ComponentSync.resetOverrides(&root.children[0], component: main, properties: ["text.color"])
        #expect(root.children[0].overrides == ["text.content"])
        #expect(root.children[0].text?.color == main.children[0].text?.color)
        #expect(root.children[0].text?.content == "Go")

        ComponentSync.resetOverrides(&root, component: main, properties: nil)
        #expect(root.overrides.isEmpty && root.children[0].overrides.isEmpty)
        #expect(root.fill == Self.red)
        #expect(root.x == 420)
        #expect(root.children[0].text?.content == "OK")
        document.update(at: [1]) { $0 = root }
        #expect(instance(document) == root)
    }

    @Test func detachClearsComponentFields() {
        let document = edit(componentFixture()) { $0.update(at: [1, 0]) { $0.text?.content = "Go" } }
        var root = instance(document)
        ComponentSync.detach(&root)
        #expect(root.instance == nil && root.source == nil && root.overrides.isEmpty)
        #expect(root.children[0].source == nil && root.children[0].overrides.isEmpty)
        #expect(root.children[0].text?.content == "Go")
    }
}
