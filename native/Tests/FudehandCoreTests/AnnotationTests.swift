import Foundation
import Testing
import FudehandCore

private func document() -> DesignDocument {
    var frame = DesignNode(id: "f", type: .frame, x: 100, y: 50, width: 300, height: 200)
    frame.children = [DesignNode(id: "a", type: .rectangle, x: 10, y: 20, width: 50, height: 40)]
    return DesignDocument(nodes: [frame, DesignNode(id: "b", type: .ellipse, x: 500, y: 0)])
}

@Test func addingAnAnnotationPinsItInsideTheLayer() throws {
    var doc = document()
    let note = try doc.addAnnotation(on: "a", x: 70, y: -5, text: "  Tighten this padding \n", author: .person)
    #expect(note.node == "a" && note.x == 50 && note.y == 0 && note.text == "Tighten this padding" && note.author == .person)
    #expect(doc.annotations == [note] && doc.annotations(on: "a") == [note] && doc.annotations(on: "f").isEmpty)
    #expect(!doc.allIDs().contains(note.id))
    #expect(throws: DesignError("Layer not found: zz")) { try doc.addAnnotation(on: "zz", x: 0, y: 0, text: "x", author: .person) }
}

@Test func emptyTextIsRejected() {
    var doc = document()
    #expect(throws: DesignError("text must not be empty")) { try doc.addAnnotation(on: "a", x: 0, y: 0, text: " \n ", author: .person) }
    #expect(doc.annotations.isEmpty)
}

@Test func repliesEditsAndDeletesAddressAnnotationsAndReplies() throws {
    var doc = document()
    let note = try doc.addAnnotation(on: "f", x: 10, y: 10, text: "Why two buttons?", author: .person)
    let reply = try doc.replyToAnnotation(note.id, text: "One is secondary", author: .agent)
    let second = try doc.replyToAnnotation(reply.id, text: "Then make it quieter", author: .person)
    #expect(doc.annotations[0].replies.map(\.text) == ["One is secondary", "Then make it quieter"])
    #expect(doc.annotation(containing: second.id)?.id == note.id && doc.annotations[0].count == 3)
    try doc.updateAnnotation(reply.id, text: "It is the secondary action")
    try doc.updateAnnotation(note.id, text: "Why are there two buttons?")
    #expect(doc.annotations[0].text == "Why are there two buttons?" && doc.annotations[0].replies[0].text == "It is the secondary action")
    try doc.deleteAnnotation(reply.id)
    #expect(doc.annotations[0].replies.map(\.id) == [second.id])
    try doc.deleteAnnotation(note.id)
    #expect(doc.annotations.isEmpty)
    #expect(throws: DesignError("Annotation not found: \(note.id)")) { try doc.deleteAnnotation(note.id) }
    #expect(throws: DesignError("Annotation not found: nope")) { try doc.replyToAnnotation("nope", text: "x", author: .agent) }
    #expect(throws: DesignError("Annotation not found: nope")) { try doc.updateAnnotation("nope", text: "x") }
}

@Test func anchorFollowsTheLayerAndStaysInsideIt() {
    let note = DesignAnnotation(id: "n", node: "a", x: 45, y: 30, author: .person, text: "x")
    #expect(note.anchor(in: Rect(x: 110, y: 70, width: 50, height: 40)) == Point(x: 155, y: 100))
    #expect(note.anchor(in: Rect(x: 0, y: 0, width: 20, height: 10)) == Point(x: 20, y: 10))
}

@Test func editsShareTheUndoHistoryAndDeletingALayerDeletesItsAnnotations() throws {
    var e = DesignEditor(document: document(), measure: fakeMeasure)
    try e.perform("Add Annotation") { try $0.addAnnotation(on: "a", x: 5, y: 5, text: "Child note", author: .person) }
    try e.perform("Add Annotation") { try $0.addAnnotation(on: "b", x: 5, y: 5, text: "Other note", author: .agent) }
    #expect(e.document.annotations.count == 2 && e.undoName == "Add Annotation")
    try e.perform("Move Layer") { try $0.move("a", parent: nil, index: nil) }
    #expect(e.document.annotations.count == 2)
    try e.perform("Delete Layers") { try $0.delete(["a"]) }
    #expect(e.document.annotations.map(\.text) == ["Other note"])
    #expect(e.undo() && e.document.annotations.count == 2)
    #expect(e.undo() && e.undo() && e.document.annotations.map(\.text) == ["Child note"])
}

@Test func annotationsAreSavedAndReopened() throws {
    var doc = document()
    let note = try doc.addAnnotation(on: "a", x: 12.5, y: 8, text: "Line one\nLine two", author: .person)
    try doc.replyToAnnotation(note.id, text: "Done", author: .agent)
    let data = try doc.encoded()
    #expect(String(decoding: data, as: UTF8.self).contains("\"version\" : 7"))
    #expect(try DesignDocument.decode(data) == doc)
    #expect(!String(decoding: try document().encoded(), as: UTF8.self).contains("annotations"))
}

@Test func filesWithoutAnnotationsOpenAndBadAnnotationsAreRejected() throws {
    func open(_ annotations: String) throws -> DesignDocument {
        let json = #"{"format":"fudehand.design","version":7,"nodes":[{"id":"r","type":"rectangle","x":0,"y":0,"width":10,"height":10}]"#
            + (annotations.isEmpty ? "" : #","annotations":"# + annotations) + "}"
        return try DesignDocument.decode(Data(json.utf8))
    }
    #expect(try open("").annotations.isEmpty)
    let good = try open(#"[{"id":"n","node":"r","x":1,"y":2,"text":"Hi","replies":[{"id":"m","author":"agent","text":"Yo"}]}]"#)
    #expect(good.annotations == [DesignAnnotation(id: "n", node: "r", x: 1, y: 2, author: .person, text: "Hi",
                                                  replies: [AnnotationReply(id: "m", author: .agent, text: "Yo")])])
    #expect(throws: DesignError("Annotation n is pinned to a missing layer: q")) { try open(#"[{"id":"n","node":"q","x":1,"y":2,"text":"Hi"}]"#) }
    #expect(throws: DesignError("Duplicate annotation id: n")) {
        try open(#"[{"id":"n","node":"r","x":1,"y":2,"text":"Hi","replies":[{"id":"n","text":"Yo"}]}]"#)
    }
    #expect(throws: DesignError("Annotation n: text must not be empty")) { try open(#"[{"id":"n","node":"r","x":1,"y":2,"text":" "}]"#) }
    #expect(throws: DesignError("Annotation n: x must be a number from 0 to 1000000")) { try open(#"[{"id":"n","node":"r","x":-1,"y":2,"text":"Hi"}]"#) }
    #expect(throws: DesignError("Annotation n: unsupported field color")) { try open(##"[{"id":"n","node":"r","x":1,"y":2,"text":"Hi","color":"#FF0000"}]"##) }
    #expect(throws: DesignError("Annotation n: author must be one of person, agent")) {
        try open(#"[{"id":"n","node":"r","x":1,"y":2,"text":"Hi","author":"bot"}]"#)
    }
    #expect(throws: DesignError("annotations must be an array")) { try open(#"{}"#) }
}

@Test func markersSkipHiddenLayersAndUseCanvasCoordinates() throws {
    var doc = document()
    try doc.addAnnotation(on: "a", x: 5, y: 6, text: "Child", author: .person)
    try doc.addAnnotation(on: "b", x: 1, y: 1, text: "Ellipse", author: .person)
    let markers = DesignIndex(doc).annotationMarkers()
    #expect(markers.map(\.annotation.text) == ["Child", "Ellipse"] && markers[0].anchor == Point(x: 115, y: 76))
    try doc.update("f") { $0.visible = false }
    #expect(DesignIndex(doc).annotationMarkers().map(\.annotation.text) == ["Ellipse"])
}
