import Foundation
import Testing
@testable import FudehandCore

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
private let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>"#.utf8)

private func node(_ object: [String: Any]) throws -> DesignNode { try DesignJSON.node(from: object) }

private func export(_ object: [String: Any], icons: ((String) -> (data: Data, ext: String)?)? = nil) throws -> DesignHTMLExport {
    let fallback: (String) -> (data: Data, ext: String)? = { _ in (svg, "svg") }
    return try DesignHTML.export(node(object), iconArtwork: icons ?? fallback)
}

/// The declarations of the CSS rule for the element carrying `data-layer-id="id"`.
private func rule(_ result: DesignHTMLExport, _ id: String) -> [String] {
    let html = result.html
    guard let tag = html.range(of: #"class="[^"]+" data-layer-id="\#(id)""#, options: .regularExpression) else { return [] }
    let name = html[tag].split(separator: "\"")[1]
    guard let start = html.range(of: ".\(name) { "), let end = html[start.upperBound...].range(of: " }") else { return [] }
    return html[start.upperBound..<end.lowerBound].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func frame(_ id: String, layout: [String: Any]? = nil, children: [[String: Any]] = [], extra: [String: Any] = [:]) -> [String: Any] {
    var object: [String: Any] = ["id": id, "type": "frame", "name": id, "x": 0, "y": 0, "width": 320, "height": 200, "children": children]
    if let layout { object["layout"] = layout }
    return object.merging(extra) { $1 }
}

private func rect(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    ["id": id, "type": "rectangle", "name": id, "x": 10, "y": 20, "width": 40, "height": 30].merging(extra) { $1 }
}

@Test func rootIsRelativeWithItsSize() throws {
    let result = try export(frame("root", extra: ["fill": "#FFFFFF"]))
    #expect(rule(result, "root").contains("position: relative"))
    #expect(rule(result, "root").contains("width: 320px"))
    #expect(rule(result, "root").contains("height: 200px"))
    #expect(rule(result, "root").contains("background: #FFFFFF"))
    #expect(result.html.hasPrefix("<!doctype html>"))
    #expect(result.files["index.html"] == Data(result.html.utf8))
}

@Test func autoLayoutMapsToFlexbox() throws {
    let aligns: [(String, String)] = [("start", "flex-start"), ("center", "center"), ("end", "flex-end"), ("space-between", "space-between")]
    for (align, justify) in aligns {
        let result = try export(frame("root", layout: ["direction": "horizontal", "spacing": 12, "align": align,
                                                       "padding": ["top": 8, "right": 16, "bottom": 8, "left": 16]]))
        let css = rule(result, "root")
        #expect(css.contains("display: flex"))
        #expect(css.contains("flex-direction: row"))
        #expect(css.contains("gap: 12px"))
        #expect(css.contains("padding: 8px 16px 8px 16px"))
        #expect(css.contains("justify-content: \(justify)"))
    }
    let crosses: [(String, String)] = [("start", "flex-start"), ("center", "center"), ("end", "flex-end"), ("stretch", "stretch")]
    for (cross, items) in crosses {
        let css = rule(try export(frame("root", layout: ["direction": "vertical", "crossAlign": cross])), "root")
        #expect(css.contains("flex-direction: column"))
        #expect(css.contains("align-items: \(items)"))
    }
}

@Test func sizingInAutoLayout() throws {
    let result = try export(frame("root", layout: ["direction": "horizontal"], children: [
        rect("fixed"),
        rect("fills", ["sizing": ["horizontal": "fill", "vertical": "fill"]]),
        frame("hugs", layout: ["direction": "vertical"], extra: ["sizing": ["horizontal": "hug", "vertical": "hug"]]),
    ]))
    #expect(rule(result, "fixed").contains("width: 40px"))
    #expect(rule(result, "fixed").contains("height: 30px"))
    #expect(!rule(result, "fixed").contains { $0.hasPrefix("position") })
    let fills = rule(result, "fills")
    #expect(fills.contains("flex: 1 1 0"))
    #expect(fills.contains("min-width: 0"))
    #expect(fills.contains("align-self: stretch"))
    #expect(!fills.contains { $0.hasPrefix("width") || $0.hasPrefix("height") })
    #expect(!rule(result, "hugs").contains { $0.hasPrefix("width") || $0.hasPrefix("height") })
}

@Test func crossAxisStretchFromTheParent() throws {
    let result = try export(frame("root", layout: ["direction": "vertical", "crossAlign": "stretch"], children: [rect("row")]))
    #expect(!rule(result, "row").contains { $0.hasPrefix("width") })
    #expect(rule(result, "row").contains("height: 30px"))
}

@Test func groupsKeepTheirSizeInAutoLayout() throws {
    let group: [String: Any] = ["id": "g", "type": "group", "name": "g", "x": 0, "y": 0, "width": 40, "height": 30,
                                "sizing": ["horizontal": "fill"], "children": [rect("inner", ["x": 0, "y": 0])]]
    let result = try export(frame("root", layout: ["direction": "horizontal", "crossAlign": "stretch"], children: [group]))
    #expect(rule(result, "g").contains("width: 40px"))
    #expect(rule(result, "g").contains("height: 30px"))
    #expect(rule(result, "g").contains("position: relative"))
    #expect(rule(result, "inner").contains("position: absolute"))
}

@Test func childrenOfAPlainFrameAreAbsolute() throws {
    let css = rule(try export(frame("root", children: [rect("box")])), "box")
    #expect(css.contains("position: absolute"))
    #expect(css.contains("left: 10px"))
    #expect(css.contains("top: 20px"))
    #expect(css.contains("width: 40px"))
    #expect(css.contains("height: 30px"))
}

@Test func hiddenLayersAreLeftOut() throws {
    let result = try export(frame("root", children: [rect("gone", ["visible": false])]))
    #expect(!result.html.contains("gone"))
}

@Test func shapesStrokesAndClipping() throws {
    let result = try export(frame("root", children: [
        ["id": "dot", "type": "ellipse", "name": "dot", "width": 10, "height": 10, "fill": "#FF000080"],
        rect("card", ["cornerRadius": 12, "opacity": 0.5, "stroke": ["color": "#112233", "width": 2]]),
    ], extra: ["clipsContent": true]))
    #expect(rule(result, "dot").contains("border-radius: 50%"))
    #expect(rule(result, "dot").contains("background: rgba(255, 0, 0, 0.502)"))
    let card = rule(result, "card")
    #expect(card.contains("border-radius: 12px"))
    #expect(card.contains("opacity: 0.5"))
    #expect(card.contains("outline: 2px solid #112233"))
    #expect(card.contains("outline-offset: -2px"))
    #expect(rule(result, "root").contains("overflow: hidden"))
    #expect(!rule(try export(frame("root", extra: ["clipsContent": false])), "root").contains("overflow: hidden"))
}

@Test func textIsEscapedAndStyled() throws {
    let result = try export(frame("root", layout: ["direction": "vertical"], children: [
        ["id": "t", "type": "text", "name": "t", "width": 100, "height": 20,
         "text": ["content": "a < b & \"c\"\nnext", "fontSize": 16, "fontWeight": 600, "fontFamily": "Avenir Next",
                  "color": "#333333", "align": "center", "lineHeight": 1.5, "autoResize": "height"]],
        ["id": "label", "type": "text", "name": "label", "width": 50, "height": 20, "text": ["content": "Hi", "autoResize": "width-and-height"]],
    ]))
    #expect(result.html.contains("a &lt; b &amp; &quot;c&quot;\nnext"))
    let css = rule(result, "t")
    #expect(css.contains(#"font-family: "Avenir Next", -apple-system, BlinkMacSystemFont, sans-serif"#))
    #expect(css.contains("font-size: 16px"))
    #expect(css.contains("font-weight: 600"))
    #expect(css.contains("line-height: 1.5"))
    #expect(css.contains("color: #333333"))
    #expect(css.contains("text-align: center"))
    #expect(css.contains("white-space: pre-wrap"))
    #expect(css.contains("width: 100px"))
    #expect(!css.contains { $0.hasPrefix("height") })
    let label = rule(result, "label")
    #expect(label.contains("white-space: pre"))
    #expect(label.contains("font-family: -apple-system, BlinkMacSystemFont, sans-serif"))
    #expect(label.contains("line-height: normal"))
    #expect(!label.contains { $0.hasPrefix("width") || $0.hasPrefix("height") })
}

@Test func imagesBecomeAssetFiles() throws {
    // Built directly: file validation would decode these stand-in bytes as real images.
    func image(_ id: String, _ data: Data, _ fit: ImageFit) -> DesignNode {
        var layer = DesignNode(id: id, type: .image, name: "Photo", width: 40, height: 40)
        layer.image = DesignImage(data: data, fit: fit)
        return layer
    }
    var root = try node(frame("root"))
    root.children = [image("a", png, .fill), image("b", jpeg, .fit), image("c", svg, .stretch)]
    let result = try DesignHTML.export(root)
    #expect(result.assets == ["a": "assets/photo.png", "b": "assets/photo-2.jpg", "c": "assets/photo-3.svg"])
    #expect(result.files["assets/photo.png"] == png)
    #expect(result.files["assets/photo-2.jpg"] == jpeg)
    #expect(result.files["assets/photo-3.svg"] == svg)
    #expect(result.html.contains(#"<img class="photo" data-layer-id="a" src="assets/photo.png" alt="Photo">"#))
    #expect(rule(result, "a").contains("object-fit: cover"))
    #expect(rule(result, "b").contains("object-fit: contain"))
    #expect(rule(result, "c").contains("object-fit: fill"))
    #expect(rule(result, "a").contains("overflow: hidden"))
}

@Test func iconsAreMaskedAndSharedByName() throws {
    var asked: [String] = []
    let result = try export(frame("root", children: [
        ["id": "i1", "type": "icon", "name": "Home", "width": 24, "height": 24, "icon": ["name": "lucide/house", "color": "#0A7AFF"]],
        ["id": "i2", "type": "icon", "name": "Home", "width": 24, "height": 24, "icon": ["name": "lucide/house", "color": "#000000"]],
        ["id": "i3", "type": "icon", "name": "Gear", "width": 24, "height": 24, "icon": ["name": "sf/gearshape.fill"]],
    ]), icons: { name in asked.append(name); return name.hasPrefix("sf/") ? (png, "png") : (svg, "svg") })
    #expect(asked == ["lucide/house", "sf/gearshape.fill"])
    #expect(result.assets == ["i1": "assets/icons/lucide-house.svg", "i2": "assets/icons/lucide-house.svg", "i3": "assets/icons/sf-gearshape-fill.png"])
    #expect(result.files["assets/icons/sf-gearshape-fill.png"] == png)
    let css = rule(result, "i1")
    #expect(css.contains("background-color: #0A7AFF"))
    #expect(css.contains("mask: url(assets/icons/lucide-house.svg) center / contain no-repeat"))
    #expect(css.contains("-webkit-mask: url(assets/icons/lucide-house.svg) center / contain no-repeat"))
    #expect(result.html.contains(#"<span class="home" data-layer-id="i1" role="img" aria-label="Home"></span>"#))
}

@Test func missingIconArtworkIsAnError() throws {
    let icon: [String: Any] = ["id": "i", "type": "icon", "name": "x", "icon": ["name": "lucide/nope"]]
    #expect(throws: DesignError("No artwork for icon lucide/nope")) { try export(frame("root", children: [icon]), icons: { _ in nil }) }
}

@Test func classNamesAreUniqueSlugs() throws {
    let result = try export(frame("root", children: [
        rect("a", ["name": "Sign In Button"]), rect("b", ["name": "Sign In Button"]), rect("c", ["name": "主按钮"]), rect("d", ["name": "2 Columns"]),
    ]))
    #expect(result.html.contains(#"class="sign-in-button" data-layer-id="a""#))
    #expect(result.html.contains(#"class="sign-in-button-2" data-layer-id="b""#))
    #expect(result.html.contains(#"class="rectangle" data-layer-id="c""#))
    #expect(result.html.contains(#"class="layer-2-columns" data-layer-id="d""#))
}

@Test func aSingleNonFrameLayerExports() throws {
    let result = try export(["id": "t", "type": "text", "name": "Hello", "width": 80, "height": 20, "text": ["content": "Hello"]])
    #expect(rule(result, "t").contains("position: relative"))
    #expect(result.html.contains(">Hello</div>"))
}
