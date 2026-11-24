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
        #expect(document.node(more)?.variant == ["Property 1": "Hover 2 2"])
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
        #expect(LayerClipboard.target(selection: [set], in: document, excluding: []) == nil)
        let rectangle = try LayerClipboard(copying: ["r"], from: document)
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

    @Test func deleteSetDetachesAllInstances() throws {
        var (document, set) = try combined()
        try document.delete([set])
        #expect(document.node("ia")?.instance == nil && document.node("ib")?.instance == nil)
        #expect(document.node("a") == nil && document.node("b") == nil)
        try document.validateComponents()
    }
}
