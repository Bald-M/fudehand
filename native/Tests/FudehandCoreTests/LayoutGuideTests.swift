import Foundation
import Testing
@testable import FudehandCore

private func columns(_ count: Int, align: LayoutGuideAlign = .stretch, width: Double = 60, gutter: Double = 20, margin: Double = 0) -> LayoutGuide {
    var guide = LayoutGuide(type: .columns)
    guide.count = count; guide.align = align; guide.width = width; guide.gutter = gutter; guide.margin = margin
    return guide
}

private func spans(_ guide: LayoutGuide, _ length: Double) -> [[Double]] {
    guide.bands(length: length).map { [$0.lowerBound, $0.upperBound] }
}

@Test func stretchedColumnsShareTheWidthBetweenMargins() {
    #expect(spans(columns(4, gutter: 20, margin: 20), 400) == [[20, 95], [115, 190], [210, 285], [305, 380]])
}

@Test func placedColumnsKeepTheirWidth() {
    #expect(spans(columns(2, align: .start, width: 50, gutter: 10, margin: 5), 200) == [[5, 55], [65, 115]])
    #expect(spans(columns(2, align: .end, width: 50, gutter: 10, margin: 5), 200) == [[85, 135], [145, 195]])
    // Centered columns ignore the margin.
    #expect(spans(columns(2, align: .center, width: 50, gutter: 10, margin: 5), 200) == [[45, 95], [105, 155]])
}

@Test func columnsThatDoNotFitDrawNothing() {
    #expect(spans(columns(3, gutter: 20, margin: 30), 100).isEmpty)
}

@Test func gridLinesFallInsideTheFrame() {
    var grid = LayoutGuide(type: .grid)
    grid.size = 30
    #expect(grid.gridLines(length: 100) == [30, 60, 90])
    #expect(grid.gridLines(length: 90) == [30, 60])
    #expect(grid.bands(length: 100).isEmpty)
}

@Test func columnAndRowBandsBecomeRectanglesInTheFrame() {
    let frame = Rect(x: 100, y: 50, width: 400, height: 300)
    #expect(columns(4, gutter: 20, margin: 20).rects(in: frame).first == Rect(x: 120, y: 50, width: 75, height: 300))
    var rows = columns(2, align: .start, width: 50, gutter: 10, margin: 5)
    rows.type = .rows
    #expect(rows.rects(in: frame) == [Rect(x: 100, y: 55, width: 400, height: 50), Rect(x: 100, y: 115, width: 400, height: 50)])
    #expect(LayoutGuide(type: .grid).rects(in: frame).isEmpty)
}

@Test func snappingTargetsAreTheBandEdges() {
    let frame = Rect(x: 100, y: 50, width: 200, height: 300)
    let guide = columns(1, align: .start, width: 50, gutter: 0, margin: 10)
    #expect(guide.snapRects(in: frame) == [Rect(x: 110, y: 50, width: 0, height: 300), Rect(x: 160, y: 50, width: 0, height: 300)])
}

// MARK: JSON

private func frame(_ guides: Any) -> [String: Any] {
    ["id": "f", "type": "frame", "layoutGuides": guides]
}

private func message(_ object: [String: Any]) -> String? {
    do { _ = try DesignJSON.node(from: object); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

@Test func layoutGuidesRoundTripThroughJSON() throws {
    var node = DesignNode(id: "f", type: .frame)
    var hidden = columns(3, align: .start, width: 48, gutter: 16, margin: 24)
    hidden.visible = false
    hidden.color = DesignColor(r: 0, g: 0, b: 1, a: 1)
    node.layoutGuides = [LayoutGuide(type: .grid), hidden]
    let object = DesignJSON.object(node, includeImageData: true)
    let written = try #require(object["layoutGuides"] as? [[String: Any]])
    #expect(written[0]["type"] as? String == "grid")
    #expect(written[0]["size"] as? Double == 10)
    #expect(written[0]["count"] == nil)
    #expect(written[1]["width"] as? Double == 48)
    #expect(written[1]["visible"] as? Bool == false)
    #expect(try DesignJSON.node(from: object) == node)
}

@Test func stretchedGuidesDoNotWriteTheirWidth() {
    var node = DesignNode(id: "f", type: .frame)
    node.layoutGuides = [columns(5)]
    let written = DesignJSON.object(node, includeImageData: true)["layoutGuides"] as? [[String: Any]]
    #expect(written?.first?["width"] == nil)
    #expect(written?.first?["count"] as? Int == 5)
}

@Test func layoutGuidesUseFigmaDefaults() throws {
    let node = try DesignJSON.node(from: frame([["type": "rows"]]))
    let guide = try #require(node.layoutGuides.first)
    #expect(guide.type == .rows && guide.count == 5 && guide.align == .stretch && guide.gutter == 20 && guide.margin == 0)
    #expect(guide.color.hex == "#FF00001A" && guide.visible)
}

@Test func layoutGuidesAreValidated() {
    #expect(message(["id": "r", "type": "rectangle", "layoutGuides": []]) == "Layer r: rectangle does not support layoutGuides")
    #expect(message(frame("grid")) == "Layer f: layoutGuides must be an array of objects")
    #expect(message(frame([["size": 4]])) == "Layer f: missing layoutGuides[0].type")
    #expect(message(frame([["type": "dots"]])) == "Layer f: layoutGuides[0].type must be one of grid, columns, rows; got dots")
    #expect(message(frame([["type": "grid", "size": 0.5]])) == "Layer f: layoutGuides[0].size must not be less than 1")
    #expect(message(frame([["type": "grid", "count": 3]])) == "Layer f: unsupported field layoutGuides[0].count")
    #expect(message(frame([["type": "grid"], ["type": "columns", "count": 2.5]])) == "Layer f: layoutGuides[1].count must be an integer")
    #expect(message(frame([["type": "rows", "count": 0]])) == "Layer f: layoutGuides[0].count must not be less than 1")
    #expect(message(frame([["type": "columns", "gutter": -1]])) == "Layer f: layoutGuides[0].gutter must not be negative")
    #expect(message(frame([["type": "columns", "width": 40]]))
            == "Layer f: layoutGuides[0].width only applies when align is start, center, or end")
    #expect(message(frame([["type": "columns", "align": "start", "width": 40]])) == nil)
}

@Test func patchReplacesOrClearsLayoutGuides() throws {
    var node = DesignNode(id: "f", type: .frame)
    node.layoutGuides = [LayoutGuide(type: .grid)]
    try DesignJSON.apply(["layoutGuides": [["type": "columns", "count": 12]]], to: &node)
    #expect(node.layoutGuides.map(\.type) == [.columns] && node.layoutGuides[0].count == 12)
    try DesignJSON.apply(["layoutGuides": NSNull()], to: &node)
    #expect(node.layoutGuides.isEmpty)
}

@Test func filesWithoutLayoutGuidesStillOpen() throws {
    let json = #"{"format":"fudehand.design","version":5,"nodes":[{"id":"f","type":"frame","name":"F","x":0,"y":0,"width":10,"height":10}]}"#
    let document = try DesignDocument.decode(Data(json.utf8))
    #expect(document.nodes[0].layoutGuides.isEmpty)
    #expect(DesignDocument.formatVersion == 6)
}

// MARK: Index

@Test func indexListsVisibleGuidesOfVisibleFrames() {
    var outer = DesignNode(id: "outer", type: .frame, x: 100, y: 100, width: 200, height: 200)
    outer.layoutGuides = [LayoutGuide(type: .grid)]
    var inner = DesignNode(id: "inner", type: .frame, x: 150, y: 10, width: 100, height: 50)
    var hidden = LayoutGuide(type: .columns)
    hidden.visible = false
    inner.layoutGuides = [hidden, LayoutGuide(type: .rows)]
    var hiddenFrame = DesignNode(id: "hiddenFrame", type: .frame)
    hiddenFrame.visible = false
    var insideHidden = DesignNode(id: "insideHidden", type: .frame)
    insideHidden.layoutGuides = [LayoutGuide(type: .grid)]
    hiddenFrame.children = [insideHidden]
    hiddenFrame.layoutGuides = [LayoutGuide(type: .grid)]
    var noGuides = DesignNode(id: "plain", type: .frame)
    noGuides.children = []
    outer.children = [inner]
    let index = DesignIndex(DesignDocument(nodes: [outer, hiddenFrame, noGuides]))
    #expect(index.guideFrames.map(\.id) == ["outer", "inner"])
    let innerEntry = index.guideFrames[1]
    #expect(innerEntry.rect == Rect(x: 250, y: 110, width: 100, height: 50))
    #expect(innerEntry.guides.map(\.type) == [.rows])
    // The outer frame clips its content, so the inner frame's guides are cut at its right edge.
    #expect(innerEntry.clip == Rect(x: 250, y: 110, width: 50, height: 50))
    #expect(index.guideFrames[0].clip == Rect(x: 100, y: 100, width: 200, height: 200))
}

// MARK: Resize snapping

@Test func resizeSnapsTheDraggedEdgesOnly() {
    let target = Rect(x: 120, y: 0, width: 0, height: 300)
    let result = Snapping.snapEdges(Rect(x: 0, y: 0, width: 116, height: 50), handle: .right, to: [target], threshold: 6)
    #expect(result.rect == Rect(x: 0, y: 0, width: 120, height: 50))
    #expect(result.guides == [Guide(axis: .vertical, position: 120, start: 0, end: 300)])
    let left = Snapping.snapEdges(Rect(x: 117, y: 0, width: 100, height: 50), handle: .left, to: [target], threshold: 6)
    #expect(left.rect == Rect(x: 120, y: 0, width: 97, height: 50))
    // An edge that is not being dragged never snaps.
    #expect(Snapping.snapEdges(Rect(x: 117, y: 0, width: 100, height: 50), handle: .right, to: [target], threshold: 6).rect
            == Rect(x: 117, y: 0, width: 100, height: 50))
}

@Test func gridLinesCanBeLimitedToARange() {
    var grid = LayoutGuide(type: .grid)
    grid.size = 10
    #expect(grid.gridLines(length: 100_000, in: 495...530) == [500, 510, 520, 530])
    #expect(grid.gridLines(length: 100, in: -50...25) == [10, 20])
    #expect(grid.gridLines(length: 100, in: 95...200).isEmpty)
}

@Test func resizeSnapsEachAxisOnItsOwn() {
    // The vertical snap would collapse the height below 1, so only the horizontal snap applies.
    let targets = [Rect(x: 120, y: 0, width: 0, height: 300), Rect(x: 0, y: 99.5, width: 500, height: 0)]
    let result = Snapping.snapEdges(Rect(x: 0, y: 100, width: 116, height: 0.5), handle: .bottomRight, to: targets, threshold: 6)
    #expect(result.rect == Rect(x: 0, y: 100, width: 120, height: 0.5))
    #expect(result.guides.map(\.axis) == [.vertical])
}
