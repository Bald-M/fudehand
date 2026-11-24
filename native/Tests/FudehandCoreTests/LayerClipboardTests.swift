import Foundation
import Testing
import FudehandCore

/// Frame "f" at (100, 50) holding rectangle "a" at (10, 20) and frame "inner"; frame "g" at (600, 0); ellipse "b" at (500, 400).
private func document() -> DesignDocument {
    var frame = DesignNode(id: "f", type: .frame, x: 100, y: 50, width: 300, height: 300)
    var a = DesignNode(id: "a", type: .rectangle, x: 10, y: 20, width: 50, height: 50)
    a.effects = [DesignEffect(type: .dropShadow)]
    var inner = DesignNode(id: "inner", type: .frame, x: 100, y: 100, width: 100, height: 100)
    var button = DesignNode(id: "button", type: .rectangle, x: 0, y: 0, width: 20, height: 20)
    button.interaction = .toggleVisibility(targets: ["dot", "b"])
    var dot = DesignNode(id: "dot", type: .ellipse, x: 30, y: 30, width: 10, height: 10)
    dot.interaction = .navigate(destination: "g", transition: PrototypeTransition())
    inner.children = [button, dot]
    frame.children = [a, inner]
    let other = DesignNode(id: "g", type: .frame, x: 600, y: 0, width: 400, height: 400)
    return DesignDocument(nodes: [frame, other, DesignNode(id: "b", type: .ellipse, x: 500, y: 400, width: 40, height: 40)])
}

private let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>"#.utf8)
private let everywhere = Rect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)

@Test func copyKeepsOutermostLayersInCanvasCoordinates() throws {
    let clip = try LayerClipboard(copying: ["a", "inner", "button"], from: document())
    #expect(clip.sources == ["a", "inner"])
    #expect(clip.nodes.map(\.id) == ["a", "inner"])
    #expect(clip.nodes[0].x == 110 && clip.nodes[0].y == 70)
    #expect(clip.nodes[1].children.map(\.id) == ["button", "dot"])
    #expect(clip.parent == .some("f") && clip.origin == Point(x: 100, y: 50))
    #expect(clip.bounds == Rect(x: 110, y: 70, width: 190, height: 180))
    #expect(throws: DesignError.self) { try LayerClipboard(copying: ["missing"], from: document()) }
    #expect(throws: DesignError.self) { try LayerClipboard(copying: [], from: document()) }
}

@Test func copiedLayersWithDifferentParentsShareNoParent() throws {
    let clip = try LayerClipboard(copying: ["a", "b"], from: document())
    #expect(clip.parent == String??.none)
    #expect(try LayerClipboard(copying: ["b", "g"], from: document()).parent == .some(nil))
}

@Test func clipboardDataRoundTripsWithImagesAndEffects() throws {
    var doc = document()
    var image = DesignNode(id: "img", type: .image, x: 0, y: 0, width: 10, height: 10)
    image.image = DesignImage(data: svg)
    try doc.insert(image, parent: "f", index: nil)
    let clip = try LayerClipboard(copying: ["a", "img"], from: doc)
    let decoded = try LayerClipboard(data: try clip.data())
    #expect(decoded == clip)
    #expect(decoded.nodes[1].image?.data == svg)
    #expect(decoded.nodes[0].effects.count == 1)
    #expect(throws: DesignError.self) { try LayerClipboard(data: Data("{}".utf8)) }
}

@Test func pasteGivesNewIDsAndOffsetsBesideTheOriginal() throws {
    var doc = document()
    let clip = try LayerClipboard(copying: ["inner"], from: doc)
    let ids = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 1, related: [])
    #expect(ids.count == 1 && ids[0] != "inner")
    let copy = try #require(doc.node(ids[0]))
    #expect(doc.parentID(of: ids[0]) == .some("f"))
    // Placed just above the original in the same parent, 10 pt down and right.
    #expect(doc.node("f")?.children.map(\.id) == ["a", "inner", ids[0]])
    #expect(copy.x == 110 && copy.y == 110)
    #expect(copy.children.count == 2 && copy.children.allSatisfy { !["button", "dot"].contains($0.id) })
    #expect(doc.allIDs().count == document().allIDs().count + 3)
    // The toggle inside the copy now targets the copied dot; layers outside the copy stay targeted.
    #expect(copy.children[0].interaction == .toggleVisibility(targets: [copy.children[1].id, "b"]))
    #expect(copy.children[1].interaction == .navigate(destination: "g", transition: PrototypeTransition()))
    // A second paste of the same clipboard moves another step.
    let again = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 2, related: Set(ids))
    #expect(doc.node(again[0])?.x == 120)
    #expect(doc.node("f")?.children.map(\.id) == ["a", "inner", ids[0], again[0]])
}

@Test func pasteAfterCutGoesBackInPlace() throws {
    var doc = document()
    let clip = try LayerClipboard(copying: ["a"], from: doc)
    try doc.delete(["a"])
    let ids = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 0, related: [])
    #expect(doc.parentID(of: ids[0]) == .some("f"))
    #expect(doc.worldRect(ids[0]) == Rect(x: 110, y: 70, width: 50, height: 50))
}

@Test func pasteIntoTheSelectedFrameKeepsTheOffsetWhenItFits() throws {
    var doc = document()
    let clip = try LayerClipboard(copying: ["a"], from: doc)
    let ids = try clip.paste(into: &doc, frame: "g", visible: everywhere, step: 1, related: [])
    #expect(doc.parentID(of: ids[0]) == .some("g"))
    #expect(doc.node(ids[0])?.x == 10 && doc.node(ids[0])?.y == 20)
    #expect(doc.node("g")?.children.map(\.id) == ids)
}

@Test func pasteIntoTheSelectedFrameCentersWhatDoesNotFit() throws {
    var doc = document()
    let clip = try LayerClipboard(copying: ["b"], from: doc)
    // b is top level at (500, 400): kept there it would fall outside "inner", so it is centered in it.
    let ids = try clip.paste(into: &doc, frame: "inner", visible: everywhere, step: 1, related: [])
    #expect(doc.parentID(of: ids[0]) == .some("inner"))
    #expect(doc.node(ids[0])?.x == 30 && doc.node(ids[0])?.y == 30)
}

@Test func pasteOutOfViewGoesToTheViewportCenter() throws {
    var doc = document()
    let clip = try LayerClipboard(copying: ["a"], from: doc)
    let view = Rect(x: 2000, y: 2000, width: 400, height: 200)
    let ids = try clip.paste(into: &doc, frame: nil, visible: view, step: 1, related: [])
    #expect(doc.parentID(of: ids[0]) == .some(nil))
    #expect(doc.worldRect(ids[0]) == Rect(x: 2175, y: 2075, width: 50, height: 50))
    #expect(doc.nodes.last?.id == ids[0])
}

@Test func pasteIntoAnotherDocumentDropsReferencesItCannotReach() throws {
    let clip = try LayerClipboard(copying: ["inner"], from: document())
    var other = DesignDocument(nodes: [DesignNode(id: "home", type: .frame, x: 0, y: 0, width: 500, height: 500)])
    let ids = try clip.paste(into: &other, frame: nil, visible: everywhere, step: 1, related: [])
    let copy = try #require(other.node(ids[0]))
    // The original parent "f" is not in this document: the copy goes to the top level, at its canvas position plus the step.
    #expect(other.parentID(of: ids[0]) == .some(nil))
    #expect(copy.x == 210 && copy.y == 160)
    #expect(copy.children[0].interaction == .toggleVisibility(targets: [copy.children[1].id]))
    #expect(copy.children[1].interaction == nil)
}

@Test func pasteTargetIsTheOneSelectedFrameNotCopiedOrPasted() {
    let doc = document()
    #expect(LayerClipboard.target(selection: ["g"], in: doc, excluding: []) == "g")
    #expect(LayerClipboard.target(selection: ["g"], in: doc, excluding: ["g"]) == nil)
    #expect(LayerClipboard.target(selection: ["a"], in: doc, excluding: []) == nil)
    #expect(LayerClipboard.target(selection: ["g", "f"], in: doc, excluding: []) == nil)
    #expect(LayerClipboard.target(selection: [], in: doc, excluding: []) == nil)
}

@Test func pasteIsOneUndoStep() throws {
    var e = DesignEditor(document: document(), measure: fakeMeasure)
    let clip = try LayerClipboard(copying: ["a", "b"], from: e.document)
    let ids = try e.perform("Paste Layers") { try clip.paste(into: &$0, frame: nil, visible: everywhere, step: 1, related: []) }
    #expect(ids.count == 2 && ids.allSatisfy { e.document.node($0) != nil })
    #expect(e.undo() && e.document == DesignEditor(document: document(), measure: fakeMeasure).document && !e.canUndo)
}

@Test func duplicateKeepsEachCopyJustAboveItsOriginal() throws {
    var doc = document()
    // "a" is in "f", "dot" in "inner", "b" at the top level, with "inner" between "a" and its copy's neighbors.
    let clip = try LayerClipboard(copying: ["a", "dot", "b"], from: doc)
    let ids = try clip.duplicate(in: &doc)
    #expect(ids.count == 3)
    #expect(doc.node("f")?.children.map(\.id) == ["a", ids[0], "inner"])
    #expect(doc.node("inner")?.children.map(\.id) == ["button", "dot", ids[1]])
    #expect(doc.nodes.map(\.id) == ["f", "g", "b", ids[2]])
    #expect(doc.node(ids[0])?.x == 20 && doc.node(ids[0])?.y == 30)
    #expect(doc.node(ids[1])?.interaction == .navigate(destination: "g", transition: PrototypeTransition()))
}

// MARK: Components

/// Frame "box" at (0, 0) holding main component "m" (frame with text "t") at (20, 20); instance "i" of it at (400, 0).
private func componentDocument() -> DesignDocument {
    var main = DesignNode(id: "m", type: .frame, name: "Button", x: 20, y: 20, width: 200, height: 60)
    main.component = true
    var label = DesignNode(id: "t", type: .text, name: "Label", x: 16, y: 20, width: 100, height: 20)
    label.text = DesignText(content: "OK")
    main.children = [label]
    var box = DesignNode(id: "box", type: .frame, x: 0, y: 0, width: 300, height: 300)
    box.children = [main]
    var existing: Set<String> = ["box", "m", "t", "i"]
    var instance = ComponentSync.makeInstance(of: main, existing: &existing)
    instance.id = "i"
    instance.x = 400
    instance.y = 0
    return DesignDocument(nodes: [box, instance])
}

private func mainComponents(_ document: DesignDocument) -> [String] {
    var ids: [String] = []
    document.forEach { if $0.component { ids.append($0.id) } }
    return ids
}

@Test func pasteMainComponentMakesInstance() throws {
    var doc = componentDocument()
    let clip = try LayerClipboard(copying: ["m"], from: doc)
    let ids = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 1, related: [])
    let copy = try #require(doc.node(ids[0]))
    #expect(!copy.component && copy.instance == "m" && copy.source == "m")
    #expect(copy.children[0].source == "t" && copy.children[0].id != "t")
    #expect(doc.parentID(of: ids[0]) == .some("box") && copy.x == 30 && copy.y == 30)
    #expect(mainComponents(doc) == ["m"])
}

@Test func duplicateInstanceMakesInstance() throws {
    var doc = componentDocument()
    let clip = try LayerClipboard(copying: ["i"], from: doc)
    let ids = try clip.duplicate(in: &doc)
    let copy = try #require(doc.node(ids[0]))
    #expect(copy.instance == "m" && copy.source == "m" && copy.children[0].source == "t")
    #expect(doc.allIDs().count == doc.nodeCount)
    // Duplicating the main component follows the same rules as pasting it in the same document.
    let main = try LayerClipboard(copying: ["m"], from: doc).duplicate(in: &doc)
    #expect(doc.node(main[0])?.instance == "m" && mainComponents(doc) == ["m"])
}

@Test func pasteContainerWithMainComponentMakesInstanceInside() throws {
    var doc = componentDocument()
    let clip = try LayerClipboard(copying: ["box"], from: doc)
    let ids = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 1, related: [])
    let inner = try #require(doc.node(ids[0])?.children.first)
    #expect(!inner.component && inner.instance == "m" && inner.source == "m")
    #expect(inner.x == 20 && inner.y == 20 && inner.children[0].source == "t")
    #expect(mainComponents(doc) == ["m"])
    #expect(doc.allIDs().count == doc.nodeCount)
}

@Test func pasteIntoOtherDocumentKeepsMainComponent() throws {
    let clip = try LayerClipboard(copying: ["m", "i"], from: componentDocument())
    var other = DesignDocument()
    let ids = try clip.paste(into: &other, frame: nil, visible: everywhere, step: 1, related: [])
    let main = try #require(other.node(ids[0]))
    #expect(main.component && main.id != "m")
    let copy = try #require(other.node(ids[1]))
    #expect(copy.instance == main.id && copy.source == main.id)
    #expect(copy.children[0].source == main.children[0].id)
    #expect(mainComponents(other) == [main.id])
}

@Test func pasteInstanceAloneIntoOtherDocumentDetaches() throws {
    let clip = try LayerClipboard(copying: ["i"], from: componentDocument())
    var other = DesignDocument()
    let ids = try clip.paste(into: &other, frame: nil, visible: everywhere, step: 1, related: [])
    let copy = try #require(other.node(ids[0]))
    #expect(copy.instance == nil && copy.source == nil && copy.overrides.isEmpty)
    #expect(copy.children[0].source == nil && copy.children[0].text?.content == "OK")
}

@Test func pasteIntoInstanceIsRefused() throws {
    var doc = componentDocument()
    let clip = try LayerClipboard(copying: ["box"], from: doc)
    #expect {
        _ = try clip.paste(into: &doc, frame: "i", visible: everywhere, step: 1, related: [])
    } throws: { ($0 as? DesignError)?.message == "Layer i is an instance; change its main component instead" }
}

@Test func pasteMainComponentIntoMainComponentIsRefused() throws {
    let refused = { (id: String) in DesignError("Layer \(id): a main component cannot be inside another main component") }
    var other = DesignNode(id: "k", type: .frame, x: 600, y: 0, width: 300, height: 300)
    other.component = true
    // Same document, Cut then Paste into another main component.
    var doc = componentDocument()
    doc.nodes.append(other)
    let cut = try LayerClipboard(copying: ["m"], from: doc)
    try doc.delete(["m"], detachingInstances: false)
    let before = doc
    #expect(throws: refused("m")) { _ = try cut.paste(into: &doc, frame: "k", visible: everywhere, step: 0, related: []) }
    #expect(doc == before)
    // Another document.
    var target = DesignDocument(nodes: [other])
    let copy = try LayerClipboard(copying: ["m"], from: componentDocument())
    #expect { _ = try copy.paste(into: &target, frame: "k", visible: everywhere, step: 1, related: []) } throws: {
        ($0 as? DesignError)?.message.hasSuffix(": a main component cannot be inside another main component") == true
    }
    #expect(target == DesignDocument(nodes: [other]))
}

@Test func pasteCopiedOutOfInstanceGoesBesideTheInstance() throws {
    var doc = componentDocument()
    doc.nodes.append(DesignNode(id: "z", type: .rectangle, x: 900, y: 0, width: 10, height: 10))
    let label = try #require(doc.node("i")?.children.first?.id)
    let clip = try LayerClipboard(copying: [label], from: doc)
    let ids = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 1, related: [])
    // In the instance's parent (the top level), just above the instance, one step down and right of the original.
    #expect(doc.nodes.map(\.id) == ["box", "i", ids[0], "z"])
    #expect(doc.worldRect(ids[0]) == Rect(x: 426, y: 30, width: 100, height: 20))
    #expect(doc.node(ids[0])?.source == nil && doc.node("i")?.children.count == 1)
    // A second paste goes above the first.
    let again = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 2, related: Set(ids))
    #expect(doc.nodes.map(\.id) == ["box", "i", ids[0], again[0], "z"])
}

@Test func pasteNestedInstanceCopiedOutOfInstanceGoesBesideTheOutermostRoot() throws {
    // Main component "k" holds an instance "ki" of "m"; instance "ik" of "k" sits in frame "page".
    var doc = componentDocument()
    var existing = doc.allIDs().union(["k", "ki", "ik", "page"])
    var inner = ComponentSync.makeInstance(of: doc.node("m")!, existing: &existing)
    inner.id = "ki"
    var main = DesignNode(id: "k", type: .frame, x: 0, y: 400, width: 300, height: 100)
    main.component = true
    main.children = [inner]
    var outer = ComponentSync.makeInstance(of: main, existing: &existing)
    outer.id = "ik"
    outer.x = 10
    var page = DesignNode(id: "page", type: .frame, x: 0, y: 600, width: 400, height: 200)
    page.children = [outer]
    doc.nodes += [main, page]
    let copied = try #require(doc.node("ik")?.children.first)
    #expect(copied.instance == "m")
    let clip = try LayerClipboard(copying: [copied.id], from: doc)
    let ids = try clip.paste(into: &doc, frame: nil, visible: everywhere, step: 1, related: [])
    #expect(doc.parentID(of: ids[0]) == .some("page"))
    #expect(doc.node("page")?.children.map(\.id) == ["ik", ids[0]])
    let pasted = try #require(doc.node(ids[0]))
    #expect(pasted.instance == "m" && pasted.source == "m")
    #expect(doc.node("ik")?.children.count == 1)
}
