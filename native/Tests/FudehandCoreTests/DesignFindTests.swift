import Foundation
import Testing
import FudehandCore

private func text(_ id: String, _ content: String, name: String? = nil) -> DesignNode {
    var node = DesignNode(id: id, type: .text, name: name ?? id)
    node.text = DesignText(content: content)
    return node
}

private func ids(_ document: DesignDocument, _ query: String) -> [String] { DesignFind.matches(in: document, query: query).map(\.id) }

@Test func findsTextContentAndNamesInDocumentOrder() {
    var frame = DesignNode(id: "f", type: .frame, name: "Home")
    frame.children = [text("t1", "Sign in"), DesignNode(id: "bg", type: .rectangle, name: "sign-in background")]
    let matches = DesignFind.matches(in: DesignDocument(nodes: [frame]), query: "sign")
    #expect(matches.map(\.id) == ["t1", "bg"])
    #expect(matches.map(\.field) == [.text, .name])
    #expect(matches.map(\.type) == [.text, .rectangle])
    #expect(matches[1].name == "sign-in background" && matches[1].excerpt == "sign-in background")
}

@Test func matchesCaseAndDiacriticInsensitively() {
    #expect(ids(DesignDocument(nodes: [text("t", "Café Menu")]), "cafe") == ["t"])
    #expect(ids(DesignDocument(nodes: [text("t", "Café Menu")]), "MENU") == ["t"])
}

@Test func listsEachLayerOnceAndPrefersText() {
    let matches = DesignFind.matches(in: DesignDocument(nodes: [text("t", "Buy now", name: "Buy now")]), query: "buy")
    #expect(matches.count == 1 && matches.first?.field == .text)
}

@Test func trimsQueryAndIgnoresBlank() {
    let document = DesignDocument(nodes: [text("t", "Café Menu")])
    #expect(ids(document, "").isEmpty && ids(document, "  \n").isEmpty)
    #expect(ids(document, " menu ") == ["t"])
}

@Test func includesHiddenAndLockedLayers() {
    var hidden = text("h", "Price"); hidden.visible = false
    var locked = text("l", "Price"); locked.locked = true
    #expect(ids(DesignDocument(nodes: [hidden, locked]), "price") == ["h", "l"])
}

@Test func excerptsLongTextAroundTheHit() {
    let content = String(repeating: "a", count: 100) + "\n" + String(repeating: "b", count: 49) + "needle" + String(repeating: "c", count: 64)
    let excerpt = try! #require(DesignFind.matches(in: DesignDocument(nodes: [text("t", content)]), query: "needle").first).excerpt
    #expect(excerpt.contains("needle"))
    #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…"))
    #expect(excerpt.count <= 82)
    #expect(!excerpt.contains("\n"))
    let short = DesignFind.matches(in: DesignDocument(nodes: [text("s", "Two\nlines")]), query: "lines").first?.excerpt
    #expect(short == "Two lines")
}

@Test func matchesNonLatinTextAndMixedQueries() {
    let document = DesignDocument(nodes: [text("zh", "立即购买 Buy"), text("en", "CAFE au lait"), text("fr", "Crème brûlée")])
    #expect(ids(document, "购买") == ["zh"])
    #expect(ids(document, "购买 buy") == ["zh"])
    #expect(ids(document, "café") == ["en"])
    #expect(ids(document, "BRULEE") == ["fr"])
    #expect(ids(DesignDocument(nodes: [text("el", "ΑΛΦΑ")]), "αλφα") == ["el"])
    #expect(DesignFind.matches(in: document, query: "brulee").first?.excerpt == "Crème brûlée")
}

/// Find compares UTF-8 bytes in place, which bridged NSStrings from JSONSerialization do not offer for non-ASCII text; decoding
/// stores layer text natively so finding in an opened file stays fast.
@Test func decodedLayerTextIsStoredAsNativeUTF8() throws {
    let data = try DesignDocument(nodes: [text("t", "立即购买", name: "购买按钮")]).encoded()
    let node = try #require(try DesignDocument.decode(data).node("t"))
    #expect(node.name.utf8.withContiguousStorageIfAvailable { _ in true } == true)
    #expect(node.text?.content.utf8.withContiguousStorageIfAvailable { _ in true } == true)
    #expect(DesignFind.matches(in: try DesignDocument.decode(data), query: "购买").map(\.id) == ["t"])
}
