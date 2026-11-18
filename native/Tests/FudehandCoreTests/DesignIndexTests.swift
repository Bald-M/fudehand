import Foundation
import Testing
import FudehandCore

/// Frame f (100,50) holding group g (10,20) holding rectangle a (5,5 30×40), and a top-level ellipse b.
private func document() -> DesignDocument {
    var group = DesignNode(id: "g", type: .group, x: 10, y: 20, width: 60, height: 60)
    group.children = [DesignNode(id: "a", type: .rectangle, x: 5, y: 5, width: 30, height: 40)]
    var frame = DesignNode(id: "f", type: .frame, x: 100, y: 50, width: 300, height: 300)
    frame.children = [group]
    return DesignDocument(nodes: [frame, DesignNode(id: "b", type: .ellipse, x: 500, y: 0)])
}

@Test func indexAnswersEveryLookupLikeTheDocument() {
    let doc = document()
    let index = DesignIndex(doc)
    for id in ["f", "g", "a", "b", "missing"] {
        #expect(index.contains(id) == (doc.node(id) != nil))
        #expect(index.node(id) == doc.node(id))
        #expect(index.indexPath(of: id) == doc.indexPath(of: id))
        #expect(index.worldRect(id) == doc.worldRect(id))
        #expect(index.parentID(of: id) == doc.parentID(of: id))
        #expect(index.ancestry(of: id) == doc.ancestry(of: id))
    }
    #expect(index.worldRect("a") == Rect(x: 115, y: 75, width: 30, height: 40))
    #expect(index.parentID(of: "a") == .some("g") && index.parentID(of: "b") == .some(nil) && index.parentID(of: "missing") == nil)
    #expect(index.ancestry(of: "a") == ["f", "g", "a"])
    #expect(index.document == doc)
}

@Test func updateAtPathChangesOnlyThatNode() throws {
    var doc = document()
    let path = try #require(DesignIndex(doc).indexPath(of: "a"))
    doc.update(at: path) { $0.x += 10 }
    #expect(doc.node("a")?.x == 15 && doc.node("g")?.x == 10)
    #expect(DesignIndex(doc).worldRect("a")?.x == 125)
}

@Test func selectableWithIndexMatchesDocument() {
    let doc = document()
    let index = DesignIndex(doc)
    let path = DesignHitTest.path(at: Point(x: 120, y: 80), in: doc)
    #expect(path == ["f", "g", "a"])
    for selection: Set<String> in [[], ["g"], ["a"], ["b"]] {
        for deep in [false, true] {
            #expect(DesignHitTest.selectable(path: path, selection: selection, index: index, deep: deep)
                    == DesignHitTest.selectable(path: path, selection: selection, document: doc, deep: deep))
        }
    }
}
