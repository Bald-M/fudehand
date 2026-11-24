import Foundation
import Testing
@testable import FudehandCore

@Suite struct ComponentVariantsTests {
    private static let red = DesignColor(r: 1, g: 0, b: 0)
    private static let setRefusal = { (set: String) in
        DesignError("Layer \(set) is a component set; use Combine as Variants or Add Variant")
    }

    private func component(_ id: String, _ name: String, y: Double) -> DesignNode {
        var main = DesignNode(id: id, type: .frame, name: name, x: 100, y: y, width: 200, height: 60)
        main.component = true
        var label = DesignNode(id: "\(id)t", type: .text, name: "Label", x: 16, y: 20, width: 100, height: 20)
        label.text = DesignText(content: name)
        main.children = [label]
        return main
    }

    /// Frame "page" holding main components "a" ("Default", at 100, 100) and "b" ("Hover", at 100, 200), rectangle "r";
    /// instances "ia" of "a" and "ib" of "b" at the top level.
    private func fixture() -> DesignDocument {
        let a = component("a", "Default", y: 100), b = component("b", "Hover", y: 200)
        var page = DesignNode(id: "page", type: .frame, x: 0, y: 0, width: 1000, height: 1000)
        page.children = [a, b, DesignNode(id: "r", type: .rectangle, x: 500, y: 500, width: 10, height: 10)]
        var existing: Set<String> = ["page", "a", "at", "b", "bt", "r", "ia", "ib"]
        var ia = ComponentSync.makeInstance(of: a, existing: &existing)
        ia.id = "ia"; ia.x = 2000
        var ib = ComponentSync.makeInstance(of: b, existing: &existing)
        ib.id = "ib"; ib.x = 2000; ib.y = 200
        return DesignDocument(nodes: [page, ia, ib])
    }

    /// The fixture with "a" and "b" combined into a set, returned with its id.
    private func combined() throws -> (DesignDocument, String) {
        var document = fixture()
        let set = try ComponentVariants.combine(["a", "b"], in: &document, propertyName: "Property 1")
        return (document, set)
    }

    /// Applies `change`, then reconciles like `DesignEditor.perform`.
    private func edit(_ document: inout DesignDocument, _ change: (inout DesignDocument) throws -> Void) rethrows {
        var next = document
        try change(&next)
        ComponentSync.reconcile(old: document, new: &next)
        document = next
    }

    // MARK: Combine

    @Test func combineWrapsComponentsKeepingIdsAndLinks() throws {
        var document = fixture()
        var set = ""
        try edit(&document) { set = try ComponentVariants.combine(["b", "a"], in: &$0, propertyName: "Property 1") }
        let node = try #require(document.node(set))
        #expect(document.node("page")?.children.map(\.id) == [set, "r"])
        #expect(node.type == .frame && node.name == "Default" && node.componentSet == ["Property 1"])
        #expect(node.frame == Rect(x: 84, y: 84, width: 232, height: 192))
        #expect(node.children.map(\.id) == ["a", "b"])
        #expect(document.worldRect("a") == Rect(x: 100, y: 100, width: 200, height: 60))
        #expect(document.worldRect("b") == Rect(x: 100, y: 200, width: 200, height: 60))
        #expect(document.node("a")?.variant == ["Property 1": "Default"])
        #expect(document.node("b")?.variant == ["Property 1": "Hover"])
        #expect(ComponentVariants.set(of: "a", in: document) == set)
        #expect(ComponentVariants.set(of: "r", in: document) == nil)
        try document.validateComponents()
        #expect(document.node("ia")?.instance == "a" && document.node("ia")?.variant == nil)
        // Instances elsewhere still follow their main component.
        try edit(&document) { try $0.update("a") { $0.fill = Self.red } }
        #expect(document.node("ia")?.fill == Self.red && document.node("ia")?.instance == "a")
    }

    @Test func combineMakesValuesUnique() throws {
        var document = fixture()
        try document.update("b") { $0.name = "Default" }
        let set = try ComponentVariants.combine(["a", "b"], in: &document, propertyName: "State")
        #expect(document.node(set)?.children.map { $0.variant?["State"] } == ["Default", "Default 2"])
        #expect(ComponentVariants.uniqueValue("X", among: []) == "X")
        #expect(ComponentVariants.uniqueValue("X", among: ["X", "X 2"]) == "X 3")
    }

    @Test func combineRequiresSameParentMainComponents() throws {
        var document = fixture()
        var top = component("c", "Top", y: 0)
        top.x = 3000
        document.nodes.append(top)
        let before = document
        #expect(throws: DesignError("Layer r is not a main component")) {
            _ = try ComponentVariants.combine(["a", "r"], in: &document, propertyName: "State")
        }
        #expect(throws: DesignError("Layers a and c do not share a parent")) {
            _ = try ComponentVariants.combine(["a", "c"], in: &document, propertyName: "State")
        }
        #expect(throws: DesignError("Layer not found: missing")) {
            _ = try ComponentVariants.combine(["missing"], in: &document, propertyName: "State")
        }
        #expect(throws: DesignError("No main components to combine")) {
            _ = try ComponentVariants.combine([], in: &document, propertyName: "State")
        }
        #expect(document == before)
        let set = try ComponentVariants.combine(["a"], in: &document, propertyName: "State")
        #expect(throws: DesignError("Layer a is already a variant of component set \(set)")) {
            _ = try ComponentVariants.combine(["a"], in: &document, propertyName: "State")
        }
    }

    @Test func combineSingleComponent() throws {
        var document = fixture()
        let set = try ComponentVariants.combine(["a"], in: &document, propertyName: "Property 1")
        let node = try #require(document.node(set))
        #expect(node.frame == Rect(x: 84, y: 84, width: 232, height: 92))
        #expect(node.children.map(\.id) == ["a"] && node.children[0].x == 16 && node.children[0].y == 16)
        #expect(document.node("page")?.children.map(\.id) == [set, "b", "r"])
        try document.validateComponents()
    }

    // MARK: Properties and values

    @Test func addPropertyGivesDefault() throws {
        var (document, set) = try combined()
        try ComponentVariants.setProperties(set, ["Property 1", "Size"], rename: [:], defaultValue: "Default", in: &document)
        #expect(document.node(set)?.componentSet == ["Property 1", "Size"])
        #expect(document.node("a")?.variant == ["Property 1": "Default", "Size": "Default"])
        #expect(document.node("b")?.variant == ["Property 1": "Hover", "Size": "Default"])
        try document.validateComponents()
    }

    @Test func renamePropertyRenamesKeys() throws {
        var (document, set) = try combined()
        try ComponentVariants.setProperties(set, ["State"], rename: ["Property 1": "State"], defaultValue: "Default", in: &document)
        #expect(document.node(set)?.componentSet == ["State"])
        #expect(document.node("b")?.variant == ["State": "Hover"])
        #expect(throws: DesignError("Component set \(set) has no variant property Nope")) {
            try ComponentVariants.setProperties(set, ["X"], rename: ["Nope": "X"], defaultValue: "Default", in: &document)
        }
        #expect(throws: DesignError("Duplicate variant property State")) {
            try ComponentVariants.setProperties(set, ["State", "State"], rename: [:], defaultValue: "Default", in: &document)
        }
        #expect(throws: DesignError("Variant property names cannot be empty")) {
            try ComponentVariants.setProperties(set, ["State", ""], rename: [:], defaultValue: "Default", in: &document)
        }
        #expect(throws: DesignError("Layer a is not a component set")) {
            try ComponentVariants.setProperties("a", ["State"], rename: [:], defaultValue: "Default", in: &document)
        }
    }

    @Test func reorderProperties() throws {
        var (document, set) = try combined()
        try ComponentVariants.setProperties(set, ["Property 1", "Size"], rename: [:], defaultValue: "Small", in: &document)
        try ComponentVariants.setProperties(set, ["Size", "Property 1"], rename: [:], defaultValue: "Default", in: &document)
        #expect(document.node(set)?.componentSet == ["Size", "Property 1"])
        #expect(document.node("a")?.variant == ["Property 1": "Default", "Size": "Small"])
        try document.validateComponents()
    }

    @Test func removingPropertyThatMakesDuplicatesIsRefused() throws {
        var (document, set) = try combined()
        try ComponentVariants.setProperties(set, ["Property 1", "Size"], rename: [:], defaultValue: "Small", in: &document)
        try ComponentVariants.setValues("a", ["Property 1": "Default", "Size": "Small"], in: &document)
        try ComponentVariants.setValues("b", ["Property 1": "Default", "Size": "Large"], in: &document)
        let before = document
        #expect(throws: DesignError("Variants a and b of component set \(set) would have the same values")) {
            try ComponentVariants.setProperties(set, ["Property 1"], rename: [:], defaultValue: "Default", in: &document)
        }
        #expect(document == before)
        #expect(throws: DesignError("Component set \(set) needs at least one variant property")) {
            try ComponentVariants.setProperties(set, [], rename: [:], defaultValue: "Default", in: &document)
        }
        // Removing the other property leaves distinct values.
        try ComponentVariants.setProperties(set, ["Size"], rename: [:], defaultValue: "Default", in: &document)
        #expect(document.node("a")?.variant == ["Size": "Small"])
        try document.validateComponents()
    }

    @Test func setValuesRefusesDuplicate() throws {
        var (document, set) = try combined()
        let before = document
        #expect(throws: DesignError("Variant b would have the same values as variant a")) {
            try ComponentVariants.setValues("b", ["Property 1": "Default"], in: &document)
        }
        #expect(throws: DesignError("Component set \(set) has no variant property Size")) {
            try ComponentVariants.setValues("b", ["Size": "Small"], in: &document)
        }
        #expect(throws: DesignError("Variant values cannot be empty")) {
            try ComponentVariants.setValues("b", ["Property 1": ""], in: &document)
        }
        #expect(throws: DesignError("Layer r is not a variant")) {
            try ComponentVariants.setValues("r", ["Property 1": "X"], in: &document)
        }
        #expect(document == before)
        try ComponentVariants.setValues("b", ["Property 1": "Pressed"], in: &document)
        #expect(document.node("b")?.variant == ["Property 1": "Pressed"])
    }

    // MARK: Add Variant

    @Test func addVariantNamesAndPlaces() throws {
        var (document, set) = try combined()
        let added = try ComponentVariants.addVariant(from: "b", in: &document)
        let node = try #require(document.node(added))
        let original = try #require(document.node("b"))
        #expect(document.node(set)?.children.map(\.id) == ["a", "b", added])
        #expect(node.component && node.variant == ["Property 1": "Hover 2"] && node.instance == nil)
        #expect(node.x == original.x && node.y == original.y + original.height + 16)
        #expect(node.children[0].id != "bt" && node.children[0].text?.content == "Hover")
        let grown = try #require(document.node(set))
        #expect(grown.width == 232 && grown.height == node.y + node.height + 16)
        try document.validateComponents()
        // From the set: copies its last variant.
        let more = try ComponentVariants.addVariant(from: set, in: &document)
        #expect(document.node(set)?.children.last?.id == more)
        #expect(document.node(more)?.variant == ["Property 1": "Hover 3"])
        // Duplicating the original again takes the next free number too; a value merely ending in a number keeps it.
        let again = try ComponentVariants.addVariant(from: "b", in: &document)
        #expect(document.node(again)?.variant == ["Property 1": "Hover 4"])
        try ComponentVariants.setValues("a", ["Property 1": "Size 12"], in: &document)
        let sized = try ComponentVariants.addVariant(from: "a", in: &document)
        #expect(document.node(sized)?.variant == ["Property 1": "Size 12 2"])
        try document.validateComponents()
        #expect(throws: DesignError("Layer r is not a variant or a component set")) {
            _ = try ComponentVariants.addVariant(from: "r", in: &document)
        }
    }

    // MARK: Structure rules

    @Test func moveIntoOrOutOfSetRefused() throws {
        var (document, set) = try combined()
        var main = component("c", "Other", y: 0)
        main.x = 3000
        document.nodes.append(main)
        let before = document
        #expect(throws: Self.setRefusal(set)) { try document.move("a", parent: "page", index: nil) }
        #expect(throws: Self.setRefusal(set)) { try document.move("r", parent: set, index: nil) }
        #expect(throws: Self.setRefusal(set)) { try document.move("c", parent: set, index: 0) }
        #expect(throws: Self.setRefusal(set)) {
            try document.insert(DesignNode(id: "new", type: .rectangle), parent: set, index: nil)
        }
        #expect(throws: DesignError("Layer \(set): a component set cannot be inside a main component")) {
            try document.move(set, parent: "c", index: nil)
        }
        #expect(document == before)
        // Moving the set itself elsewhere is an ordinary move.
        try document.move(set, parent: nil, index: nil)
        try document.validateComponents()
    }

    @Test func reorderInsideSetAllowed() throws {
        var (document, set) = try combined()
        try document.move("b", parent: set, index: 0)
        #expect(document.node(set)?.children.map(\.id) == ["b", "a"])
        #expect(document.worldRect("b") == Rect(x: 100, y: 200, width: 200, height: 60))
        try document.validateComponents()
    }

    @Test func deleteVariantDetachesItsInstances() throws {
        var (document, set) = try combined()
        try document.delete(["a"])
        #expect(document.node("ia")?.instance == nil && document.node("ia")?.source == nil)
        #expect(document.node("ib")?.instance == "b")
        #expect(document.node(set)?.children.map(\.id) == ["b"])
        try document.validateComponents()
        try document.delete(["b"])
        #expect(document.node(set)?.children.isEmpty == true && document.node(set)?.componentSet == ["Property 1"])
        try document.validateComponents()
    }

    @Test func pasteAndDuplicateAroundSets() throws {
        let everywhere = Rect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
        var (document, set) = try combined()
        // A set is never where Paste puts layers by default, and only main components go into it.
        #expect(!document.acceptsInsertedLayers(set))
        let rectangle = try LayerClipboard(copying: ["r"], from: document)
        #expect(rectangle.target(selection: [set], in: document, excluding: []) == nil)
        let before = document
        #expect(throws: Self.setRefusal(set)) {
            _ = try rectangle.paste(into: &document, frame: set, visible: everywhere, step: 1, related: [])
        }
        #expect(document == before)
        let beside = try rectangle.paste(into: &document, frame: nil, visible: everywhere, step: 1, related: [])
        #expect(document.parentID(of: beside[0]) == .some("page"))

        // Duplicating a variant adds a variant.
        let duplicated = try LayerClipboard(copying: ["b"], from: document).duplicate(in: &document)
        #expect(document.node(set)?.children.map(\.id) == ["a", "b", duplicated[0]])
        #expect(document.node(duplicated[0])?.variant == ["Property 1": "Hover 2"] && document.node(duplicated[0])?.component == true)
        try document.validateComponents()

        // A main component pasted into the set becomes a new variant.
        let main = try LayerClipboard(copying: ["a"], from: document)
        let pasted = try main.paste(into: &document, frame: set, visible: everywhere, step: 1, related: [])
        let variant = try #require(document.node(pasted[0]))
        #expect(variant.component && variant.id != "a" && variant.variant == ["Property 1": "Default 2"])
        #expect(document.node(set)?.children.last?.id == pasted[0])
        try document.validateComponents()

        // Pasted without a target, a copied variant becomes an instance beside the set.
        let instance = try main.paste(into: &document, frame: nil, visible: everywhere, step: 1, related: [])
        let copy = try #require(document.node(instance[0]))
        #expect(copy.instance == "a" && copy.variant == nil && !copy.component)
        #expect(document.parentID(of: instance[0]) == .some("page"))
        try document.validateComponents()

        // Duplicating the set makes a frame of instances; pasting it into another document keeps it a set.
        let sets = try LayerClipboard(copying: [set], from: document)
        let frame = try sets.duplicate(in: &document)
        let plain = try #require(document.node(frame[0]))
        #expect(plain.componentSet == nil && plain.children.allSatisfy { $0.instance != nil && $0.variant == nil })
        try document.validateComponents()
        var other = DesignDocument()
        let moved = try sets.paste(into: &other, frame: nil, visible: everywhere, step: 1, related: [])
        let copied = try #require(other.node(moved[0]))
        #expect(copied.componentSet == ["Property 1"] && copied.children.allSatisfy { $0.component && $0.variant != nil })
        #expect(!copied.children.contains { $0.id == "a" })
        try other.validateComponents()

        // A copied variant pasted into another document is a plain main component.
        var third = DesignDocument()
        let lone = try main.paste(into: &third, frame: nil, visible: everywhere, step: 1, related: [])
        #expect(third.node(lone[0])?.component == true && third.node(lone[0])?.variant == nil)
        try third.validateComponents()
    }

    @Test func pastedComponentsIntoSetLinkInstancesToEachOther() throws {
        let everywhere = Rect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
        var (document, set) = try combined()
        // Another document: main component "x", and main component "y" holding an instance of "x".
        let x = component("x", "Small", y: 0)
        var existing: Set<String> = ["x", "xt", "y", "yi"]
        var inner = ComponentSync.makeInstance(of: x, existing: &existing)
        inner.id = "yi"
        var y = component("y", "Large", y: 300)
        y.children.append(inner)
        let clip = try LayerClipboard(copying: ["x", "y"], from: DesignDocument(nodes: [x, y]))
        let ids = try clip.paste(into: &document, frame: set, visible: everywhere, step: 1, related: [])
        let copied = try #require(document.node(ids[1])?.children.last)
        #expect(copied.instance == ids[0] && copied.source == ids[0])
        #expect(copied.children.first?.source == document.node(ids[0])?.children.first?.id)
        try document.validateComponents()
    }

    @Test func deleteSetDetachesAllInstances() throws {
        var (document, set) = try combined()
        try document.delete([set])
        #expect(document.node("ia")?.instance == nil && document.node("ib")?.instance == nil)
        #expect(document.node("a") == nil && document.node("b") == nil)
        try document.validateComponents()
    }

    // MARK: Switching

    private func layer(_ id: String, _ type: NodeType, _ name: String) -> DesignNode {
        var node = DesignNode(id: id, type: type, name: name, x: 0, y: 0, width: 40, height: 20)
        if type == .text { node.text = DesignText(content: name) }
        return node
    }

    private func variant(_ id: String, _ values: [String: String], _ children: [DesignNode], name: String? = nil) -> DesignNode {
        var node = DesignNode(id: id, type: .frame, name: name ?? id, x: 16, y: 16, width: 200, height: 60)
        node.component = true
        node.variant = values
        node.children = children
        return node
    }

    private func componentSet(_ id: String, _ properties: [String], _ variants: [DesignNode]) -> DesignNode {
        var set = DesignNode(id: id, type: .frame, name: id, x: 0, y: 0, width: 600, height: 400)
        set.componentSet = properties
        set.children = variants
        return set
    }

    /// Appends an instance `id` of main component `componentID` at (x, y) to the top level; returns its layers' ids in order.
    @discardableResult
    private func instantiate(_ componentID: String, as id: String, in document: inout DesignDocument, x: Double = 2000,
                             y: Double = 50) -> [String] {
        var existing = document.allIDs()
        existing.insert(id)
        var instance = ComponentSync.makeInstance(of: document.node(componentID)!, existing: &existing)
        instance.id = id
        instance.x = x
        instance.y = y
        document.nodes.append(instance)
        return DesignDocument(nodes: [instance]).allIDs().sorted()
    }

    /// Component set "s" (State × Size): "v1" Default/Small holds text "Label" (toggling "Mark"), text "Mark", rectangle "Icon", frame "Box"; "v2" Hover/Small
    /// (red, 300 wide) holds text "Label" (toggling "Mark"), rectangle "Mark", rectangle "Badge", rectangle "Box"; "v3" Default/Large and "v4" Hover/Large hold text
    /// "Label".
    private func switchFixture() -> DesignDocument {
        var v2 = variant("v2", ["State": "Hover", "Size": "Small"],
                         [layer("v2t", .text, "Label"), layer("v2m", .rectangle, "Mark"), layer("v2b", .rectangle, "Badge"),
                          layer("v2x", .rectangle, "Box")])
        v2.fill = Self.red
        v2.width = 300
        var v1 = variant("v1", ["State": "Default", "Size": "Small"],
                         [layer("v1t", .text, "Label"), layer("v1m", .text, "Mark"), layer("v1i", .rectangle, "Icon"),
                          layer("v1x", .frame, "Box")])
        v1.children[0].interaction = .toggleVisibility(targets: ["v1m"])
        v2.children[0].interaction = .toggleVisibility(targets: ["v2m"])
        let set = componentSet("s", ["State", "Size"], [
            v1,
            v2,
            variant("v3", ["State": "Default", "Size": "Large"], [layer("v3t", .text, "Label")]),
            variant("v4", ["State": "Hover", "Size": "Large"], [layer("v4t", .text, "Label")]),
        ])
        return DesignDocument(nodes: [set])
    }

    private func switchVariant(_ ids: [String], _ changes: [String: String], in document: inout DesignDocument) throws {
        try edit(&document) { try ComponentVariants.switchInstances(ids, to: changes, in: &$0) }
    }

    @Test func switchRefusesAnInstanceIntoItsOwnMainComponent() throws {
        var (document, _) = try combined()
        // An instance of "a" inside variant "b" is fine; switched to "b" it would be inside its own main component.
        var existing = document.allIDs()
        var inner = ComponentSync.makeInstance(of: document.node("a")!, existing: &existing)
        inner.id = "inner"
        try edit(&document) { try $0.insert(inner, parent: "b", index: nil) }
        var next = document
        #expect(throws: DesignError("Layer inner: an instance cannot be inside its own main component")) {
            try ComponentVariants.switchInstances(["ia", "inner"], to: ["Property 1": "Hover"], in: &next)
        }
        #expect(next == document)

        // Through a nested instance: main component "c" holds an instance of "a", and "b" holds an instance of "c".
        var c = DesignNode(id: "c", type: .frame, name: "Card", x: 3000, y: 0, width: 100, height: 100)
        c.component = true
        existing = document.allIDs().union(["c"])
        var nested = ComponentSync.makeInstance(of: document.node("a")!, existing: &existing)
        nested.id = "nested"
        c.children = [nested]
        try edit(&document) {
            try $0.delete(["inner"])
            try $0.insert(c, parent: nil, index: nil)
        }
        existing = document.allIDs()
        let ofC = ComponentSync.makeInstance(of: document.node("c")!, existing: &existing)
        try edit(&document) { try $0.insert(ofC, parent: "b", index: nil) }
        next = document
        #expect(throws: DesignError("Layer nested: an instance cannot be inside its own main component")) {
            try ComponentVariants.switchInstances(["nested"], to: ["Property 1": "Hover"], in: &next)
        }
        #expect(next == document)
    }

    @Test func targetExactMatch() {
        let document = switchFixture()
        #expect(ComponentVariants.target(for: "v1", changing: ["State": "Hover"], in: document) == "v2")
        #expect(ComponentVariants.target(for: "v1", changing: ["Size": "Large"], in: document) == "v3")
        #expect(ComponentVariants.target(for: "v1", changing: ["State": "Hover", "Size": "Large"], in: document) == "v4")
        #expect(ComponentVariants.target(for: "v2", changing: [:], in: document) == "v2")
        #expect(ComponentVariants.target(for: "v1", changing: ["State": "Pressed"], in: document) == nil)
        #expect(ComponentVariants.target(for: "v1", changing: ["Color": "Red"], in: document) == nil)
        #expect(ComponentVariants.target(for: "s", changing: ["State": "Hover"], in: document) == nil)
    }

    @Test func targetClosestMatchTieFirst() {
        let values = { (a: String, b: String, c: String) in ["A": a, "B": b, "C": c] }
        let document = DesignDocument(nodes: [componentSet("s", ["A", "B", "C"], [
            variant("p1", values("a1", "b1", "c1"), []),
            variant("q3", values("a2", "b2", "c2"), []),
            variant("q1", values("a2", "b2", "c1"), []),
            variant("q2", values("a2", "b1", "c2"), []),
        ])])
        // a2/b1/c1 does not exist; q1 and q2 each share one other value with p1, q3 none: the first of the tie wins.
        #expect(ComponentVariants.target(for: "p1", changing: ["A": "a2"], in: document) == "q1")
        // a1/b1/c2 does not exist; q2 shares B with p1, q3 shares nothing.
        #expect(ComponentVariants.target(for: "p1", changing: ["C": "c2"], in: document) == "q2")
    }

    @Test func switchKeepsOverridesOnMatchedLayers() throws {
        var document = switchFixture()
        instantiate("v1", as: "i", in: &document)
        let label = try #require(document.node("i")).children[0].id
        try edit(&document) { try $0.update(label) { $0.text?.content = "Go" } }
        try switchVariant(["i"], ["State": "Hover"], in: &document)
        let instance = try #require(document.node("i"))
        #expect(instance.instance == "v2" && instance.source == "v2" && instance.overrides.isEmpty)
        #expect(instance.fill == Self.red && instance.width == 300)
        let moved = instance.children[0]
        #expect(moved.id == label && moved.source == "v2t" && moved.text?.content == "Go" && moved.overrides == ["text.content"])
        #expect(instance.children.dropFirst().allSatisfy { $0.overrides.isEmpty })
        try document.validateComponents()
        // Still linked to the new variant.
        try edit(&document) { try $0.update("v2t") { $0.text?.fontSize = 30 } }
        #expect(document.node(label)?.text?.fontSize == 30 && document.node(label)?.text?.content == "Go")
    }

    @Test func switchDropsOverridesNewLayerLacks() throws {
        var document = switchFixture()
        instantiate("v1", as: "i", in: &document)
        let mark = try #require(document.node("i")).children[1].id
        let blue = DesignColor(r: 0, g: 0, b: 1)
        try edit(&document) { try $0.update(mark) { $0.text?.content = "X"; $0.fill = blue } }
        #expect(document.node(mark)?.overrides == ["text.content", "fill"])
        try switchVariant(["i"], ["State": "Hover"], in: &document)
        let node = try #require(document.node(mark))
        #expect(node.type == .rectangle && node.text == nil && node.source == "v2m")
        #expect(node.overrides == ["fill"] && node.fill == blue)
    }

    @Test func switchDropsTypeBoundOverridesWhenTypeChanges() throws {
        var document = switchFixture()
        instantiate("v1", as: "i", in: &document)
        let box = try #require(document.node("i")).children[3].id
        let blue = DesignColor(r: 0, g: 0, b: 1)
        try edit(&document) {
            try $0.update(box) {
                $0.layout = AutoLayout(direction: .horizontal)
                $0.clipsContent = false
                $0.effects = [DesignEffect(type: .perspective)]
                $0.fill = blue
            }
        }
        #expect(document.node(box)?.overrides == ["layout", "clipsContent", "effects", "fill"])
        try switchVariant(["i"], ["State": "Hover"], in: &document)
        let node = try #require(document.node(box))
        #expect(node.type == .rectangle && node.overrides == ["fill"] && node.fill == blue)
        #expect(node.layout == nil && node.effects.isEmpty)
        #expect(try DesignDocument.decode(document.encoded()) == document)
    }

    @Test func switchDropsTypeBoundRootOverridesWhenTypeChanges() throws {
        var shape = DesignNode(id: "r", type: .rectangle, name: "Shape", x: 16, y: 100, width: 50, height: 50)
        shape.component = true
        shape.variant = ["Kind": "Shape"]
        var document = DesignDocument(nodes: [componentSet("s", ["Kind"], [variant("f", ["Kind": "Frame"], []), shape])])
        instantiate("f", as: "i", in: &document)
        let blue = DesignColor(r: 0, g: 0, b: 1)
        try edit(&document) { try $0.update("i") { $0.layout = AutoLayout(direction: .vertical); $0.fill = blue } }
        try switchVariant(["i"], ["Kind": "Shape"], in: &document)
        let node = try #require(document.node("i"))
        #expect(node.type == .rectangle && node.overrides == ["fill"] && node.layout == nil && node.fill == blue)
        #expect(try DesignDocument.decode(document.encoded()) == document)
    }

    @Test func switchMapsCarriedToggleTargets() throws {
        var document = switchFixture()
        instantiate("v1", as: "i", in: &document)
        let children = try #require(document.node("i")).children.map(\.id)
        let (label, mark, icon) = (children[0], children[1], children[2])
        try edit(&document) {
            try $0.update(label) { $0.interaction = .toggleVisibility(targets: [icon, mark, "v3"]) }
            try $0.update(mark) { $0.interaction = .toggleVisibility(targets: [icon]) }
        }
        #expect(document.node(label)?.overrides.contains("interaction") == true)
        try switchVariant(["i"], ["State": "Hover"], in: &document)
        // Targets inside the instance follow the matched layers; the unmatched icon is gone; targets outside stay.
        #expect(document.node(label)?.interaction == .toggleVisibility(targets: [mark, "v3"]))
        #expect(document.node(mark)?.interaction == nil)
        #expect(try DesignDocument.decode(document.encoded()) == document)
    }

    @Test func switchKeepsIdsAndAnnotations() throws {
        var document = switchFixture()
        instantiate("v1", as: "i", in: &document)
        let ids = try #require(document.node("i")?.children.map(\.id))
        document.annotations = [
            DesignAnnotation(id: "n1", node: ids[0], x: 0, y: 0, author: .person, text: "Label note"),
            DesignAnnotation(id: "n2", node: ids[2], x: 0, y: 0, author: .person, text: "Icon note"),
            DesignAnnotation(id: "n3", node: "i", x: 0, y: 0, author: .person, text: "Root note"),
        ]
        var editor = DesignEditor(document: document, measure: fakeMeasure)
        try editor.perform("Switch Variant") { try ComponentVariants.switchInstances(["i"], to: ["State": "Hover"], in: &$0) }
        #expect(editor.document.node("i")?.children.prefix(2).map(\.id) == Array(ids.prefix(2)))
        #expect(editor.document.annotations.map(\.id) == ["n1", "n3"])
    }

    @Test func switchRemovesUnmatchedAndAddsNew() throws {
        var document = switchFixture()
        let before = instantiate("v1", as: "i", in: &document)
        let ids = try #require(document.node("i")).children.map(\.id)
        let icon = ids[2]
        try switchVariant(["i"], ["State": "Hover"], in: &document)
        #expect(document.node(icon) == nil)
        let badge = try #require(document.node("i")?.children[2])
        #expect(badge.name == "Badge" && badge.source == "v2b" && !before.contains(badge.id) && badge.id != "v2b")
        // The label's toggle target is the instance's own mark, which kept its id; that is no override.
        let label = try #require(document.node(ids[0]))
        #expect(label.interaction == .toggleVisibility(targets: [ids[1]]) && label.overrides.isEmpty)
        // Back to the first variant: the badge goes, a new icon comes.
        try switchVariant(["i"], ["State": "Default"], in: &document)
        #expect(document.node(badge.id) == nil)
        #expect(document.node("i")?.children.map(\.source) == ["v1t", "v1m", "v1i", "v1x"])
        try document.validateComponents()
    }

    @Test func switchPairsSameNamedSiblingsInOrder() throws {
        let dots = { (prefix: String, count: Int) in (1...count).map { self.layer("\(prefix)\($0)", .rectangle, "Dot") } }
        var document = DesignDocument(nodes: [componentSet("s", ["Count"], [
            variant("v1", ["Count": "Two"], dots("v1d", 2)),
            variant("v2", ["Count": "Three"], dots("v2d", 3)),
        ])])
        instantiate("v1", as: "i", in: &document)
        let ids = try #require(document.node("i")?.children.map(\.id))
        try edit(&document) {
            try $0.update(ids[0]) { $0.opacity = 0.5 }
            try $0.update(ids[1]) { $0.opacity = 0.25 }
        }
        try switchVariant(["i"], ["Count": "Three"], in: &document)
        let children = try #require(document.node("i")?.children)
        #expect(children.map(\.source) == ["v2d1", "v2d2", "v2d3"])
        #expect(Array(children.prefix(2).map(\.id)) == ids && !ids.contains(children[2].id))
        #expect(children.map(\.opacity) == [0.5, 0.25, 1])
        // Back: the third dot is unmatched and goes.
        try switchVariant(["i"], ["Count": "Two"], in: &document)
        #expect(document.node("i")?.children.map(\.id) == ids)
        #expect(document.node("i")?.children.map(\.opacity) == [0.5, 0.25])
    }

    @Test func switchKeepsRootOverridesAndPosition() throws {
        var document = switchFixture()
        instantiate("v1", as: "i", in: &document, x: 2000, y: 50)
        let blue = DesignColor(r: 0, g: 0, b: 1)
        try edit(&document) { try $0.update("i") { $0.width = 500; $0.fill = blue; $0.y = 70 } }
        try switchVariant(["i"], ["State": "Hover"], in: &document)
        let instance = try #require(document.node("i"))
        #expect(instance.x == 2000 && instance.y == 70 && instance.width == 500 && instance.fill == blue)
        #expect(instance.overrides == ["width", "fill"] && instance.height == 60)
    }

    @Test func switchNestedInstanceSameSet() throws {
        var knobOff = layer("w1k", .text, "Knob")
        knobOff.text?.content = "Off"
        var w2 = variant("w2", ["Value": "On"], [layer("w2k", .text, "Knob")], name: "Toggle")
        w2.fill = Self.red
        let toggles = componentSet("t", ["Value"], [variant("w1", ["Value": "Off"], [knobOff], name: "Toggle"), w2])
        var box = DesignNode(id: "m", type: .frame, name: "Box", x: 0, y: 500, width: 20, height: 20)
        box.component = true
        var document = DesignDocument(nodes: [toggles, box])
        var existing = document.allIDs().union(["s", "v1", "v2", "v1x", "v2x", "i"])
        func nested(_ main: DesignNode, _ id: String) -> DesignNode {
            var node = ComponentSync.makeInstance(of: main, existing: &existing)
            node.id = id
            return node
        }
        let set = componentSet("s", ["State"], [
            variant("v1", ["State": "Default"], [nested(toggles.children[0], "v1n"), nested(box, "v1b")]),
            variant("v2", ["State": "Hover"], [nested(w2, "v2n"), layer("v2x", .frame, "Box")]),
        ])
        document.nodes.insert(set, at: 0)
        try document.validateComponents()
        instantiate("v1", as: "i", in: &document)
        let old = try #require(document.node("i")?.children)
        let knob = old[0].children[0].id
        try edit(&document) { try $0.update(knob) { $0.text?.content = "Yes" } }
        try switchVariant(["i"], ["State": "Hover"], in: &document)
        let children = try #require(document.node("i")?.children)
        let toggle = children[0]
        #expect(toggle.id == old[0].id && toggle.instance == "w2" && toggle.source == "v2n" && toggle.fill == Self.red)
        #expect(toggle.children[0].id == knob && toggle.children[0].text?.content == "Yes")
        #expect(toggle.children[0].overrides == ["text.content"])
        #expect(toggle.children[0].source == document.node("v2n")?.children[0].id)
        // "Box" is an instance in v1 but a plain frame in v2: unmatched.
        #expect(children[1].source == "v2x" && children[1].instance == nil && children[1].id != old[1].id)
        #expect(document.node(old[1].id) == nil)
        try document.validateComponents()
    }

    @Test func switchManyInstancesOwnValues() throws {
        var document = switchFixture()
        instantiate("v1", as: "i1", in: &document)
        instantiate("v3", as: "i2", in: &document, y: 300)
        try switchVariant(["i1", "i2"], ["State": "Hover"], in: &document)
        #expect(document.node("i1")?.instance == "v2" && document.node("i2")?.instance == "v4")
        #expect(document.node("i2")?.y == 300)
    }

    @Test func switchRefusesNonInstanceOrNoSet() throws {
        var document = switchFixture()
        instantiate("v1", as: "i", in: &document)
        var main = DesignNode(id: "m", type: .frame, x: 0, y: 900, width: 10, height: 10)
        main.component = true
        document.nodes.append(main)
        instantiate("m", as: "j", in: &document)
        let inner = try #require(document.node("i")).children[0].id
        let original = document
        #expect(throws: DesignError("Layer not found: nope")) {
            try ComponentVariants.switchInstances(["nope"], to: ["State": "Hover"], in: &document)
        }
        #expect(throws: DesignError("Layer v1 is not an instance")) {
            try ComponentVariants.switchInstances(["v1"], to: ["State": "Hover"], in: &document)
        }
        #expect(throws: DesignError("Layer \(inner) is not an instance")) {
            try ComponentVariants.switchInstances([inner], to: ["State": "Hover"], in: &document)
        }
        #expect(throws: DesignError("Layer j is an instance of m, which is not a variant")) {
            try ComponentVariants.switchInstances(["i", "j"], to: ["State": "Hover"], in: &document)
        }
        #expect(throws: DesignError("Component set s has no variant with State = Pressed")) {
            try ComponentVariants.switchInstances(["i"], to: ["State": "Pressed"], in: &document)
        }
        #expect(document == original)
    }
}
