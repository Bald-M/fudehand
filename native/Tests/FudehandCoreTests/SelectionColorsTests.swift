import Foundation
import Testing
import FudehandCore

private let red = try! DesignColor(hex: "#FF0000")
private let blue = try! DesignColor(hex: "#0000FF")
private let green = try! DesignColor(hex: "#00FF00")
private let translucentRed = try! DesignColor(hex: "#FF000080")

/// A frame (red fill) holding a text layer (blue text, red stroke), an icon (blue), and a group with a rectangle (green fill,
/// blue stroke); a second top-level rectangle uses a translucent red.
private func document() -> DesignDocument {
    var text = DesignNode(id: "t", type: .text)
    text.text = DesignText(content: "Hi", color: blue)
    text.stroke = DesignStroke(color: red, width: 1)
    var icon = DesignNode(id: "i", type: .icon)
    icon.icon = DesignIcon(name: "sf/house", color: blue)
    var rectangle = DesignNode(id: "r", type: .rectangle)
    rectangle.fill = green
    rectangle.stroke = DesignStroke(color: blue, width: 2)
    var group = DesignNode(id: "g", type: .group)
    group.children = [rectangle]
    var frame = DesignNode(id: "f", type: .frame)
    frame.fill = red
    frame.children = [text, icon, group]
    var other = DesignNode(id: "o", type: .rectangle)
    other.fill = translucentRed
    return DesignDocument(nodes: [frame, other])
}

private func summary(_ colors: [SelectionColor]) -> [String] { colors.map { "\($0.color.hex)×\($0.count)" } }

@Test func collectsAFrameAndAllItsChildLayersMostUsedFirst() {
    // Blue: text color, icon color, rectangle stroke; red: frame fill, text stroke; green: rectangle fill.
    #expect(summary(SelectionColors.collect(["f"], in: document())) == ["#0000FF×3", "#FF0000×2", "#00FF00×1"])
}

@Test func collectsOneLayerAndKeepsColorsThatDifferOnlyInOpacityApart() {
    #expect(summary(SelectionColors.collect(["t"], in: document())) == ["#FF0000×1", "#0000FF×1"])
    #expect(summary(SelectionColors.collect(["f", "o"], in: document())) == ["#0000FF×3", "#FF0000×2", "#00FF00×1", "#FF000080×1"])
}

@Test func countsALayerSelectedWithItsAncestorOnce() {
    #expect(summary(SelectionColors.collect(["f", "r", "g"], in: document())) == summary(SelectionColors.collect(["f"], in: document())))
    #expect(SelectionColors.collect([], in: document()).isEmpty)
    #expect(SelectionColors.collect(["missing"], in: document()).isEmpty)
}

@Test func collectsTheSameColorsThroughTheIndex() {
    let index = DesignIndex(document())
    for ids: Set<String> in [["f"], ["t"], ["o", "f"], ["f", "r", "g"], ["r", "t"], ["i", "o", "r"], [], ["missing", "o"]] {
        #expect(summary(SelectionColors.collect(ids, in: index)) == summary(SelectionColors.collect(ids, in: document())), "\(ids)")
    }
    #expect(SelectionColors.color(of: ColorUse(id: "r", property: .stroke), in: index) == blue)
    #expect(SelectionColors.color(of: ColorUse(id: "o", property: .text), in: index) == nil)
    #expect(SelectionColors.color(of: ColorUse(id: "missing", property: .fill), in: index) == nil)
}

@Test func mergesColorsWithTheSameHexValue() {
    var doc = document()
    // A picker can produce components a hair apart that still write the same hex value.
    try! doc.update("o") { $0.fill = DesignColor(r: 1.0001, g: 0, b: 0) }
    #expect(summary(SelectionColors.collect(["o", "f"], in: doc)) == ["#FF0000×3", "#0000FF×3", "#00FF00×1"])
}

private func replace(_ old: DesignColor, with new: DesignColor, under ids: Set<String>, in doc: inout DesignDocument) -> Int {
    SelectionColors.set(new, at: SelectionColors.uses(of: old, under: ids, in: doc), in: &doc)
}

@Test func replacesEveryUseInTheSelectionOnly() {
    var doc = document()
    let purple = try! DesignColor(hex: "#8000FF")
    #expect(SelectionColors.uses(of: blue, under: ["t", "g"], in: doc) == [ColorUse(id: "t", property: .text), ColorUse(id: "r", property: .stroke)])
    #expect(replace(blue, with: purple, under: ["t", "g"], in: &doc) == 2)
    #expect(doc.node("t")?.text?.color == purple && doc.node("r")?.stroke?.color == purple)
    // The icon is outside the selection and keeps its color.
    #expect(doc.node("i")?.icon?.color == blue)
    #expect(replace(red, with: purple, under: ["f"], in: &doc) == 2)
    #expect(doc.node("f")?.fill == purple && doc.node("t")?.stroke?.color == purple && doc.node("o")?.fill == translucentRed)
    #expect(summary(SelectionColors.collect(["f"], in: doc)) == ["#8000FF×4", "#0000FF×1", "#00FF00×1"])
    #expect(replace(red, with: purple, under: ["f"], in: &doc) == 0)
}

@Test func editingTheUsesOfOneColorLeavesAColorItPassesThroughAlone() {
    var doc = document()
    // A color well dragged from green through blue and on to purple: the uses recorded at the start are the only ones written.
    let greens = SelectionColors.uses(of: green, under: ["f"], in: doc)
    #expect(SelectionColors.set(blue, at: greens, in: &doc) == 1)
    #expect(summary(SelectionColors.collect(["f"], in: doc)) == ["#0000FF×4", "#FF0000×2"])
    let purple = try! DesignColor(hex: "#8000FF")
    #expect(SelectionColors.set(purple, at: greens, in: &doc) == 1)
    #expect(doc.node("r")?.fill == purple && doc.node("t")?.text?.color == blue && doc.node("i")?.icon?.color == blue)
    #expect(SelectionColors.color(of: greens[0], in: doc) == purple)
    // A use whose layer is gone is skipped.
    try! doc.delete(["r"])
    #expect(SelectionColors.set(red, at: greens, in: &doc) == 0 && SelectionColors.color(of: greens[0], in: doc) == nil)
}
