import Foundation
import Testing
@testable import FudehandCore

private func iconNode(_ fields: [String: Any]) throws -> DesignNode {
    try DesignJSON.node(from: ["id": "i", "type": "icon"].merging(fields) { $1 })
}

private func failure(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

@Test func iconRoundTripsThroughFile() throws {
    var node = DesignNode(id: "i", type: .icon, x: 4, y: 8, width: 32, height: 32)
    node.icon = DesignIcon(name: "material-rounded/home.fill", color: try DesignColor(hex: "#336699"))
    let again = try DesignDocument.decode(try DesignDocument(nodes: [node]).encoded())
    #expect(again.nodes == [node])
    #expect(DesignJSON.object(node, includeImageData: false)["icon"] as? [String: String]
            == ["name": "material-rounded/home.fill", "color": "#336699"])
}

@Test func iconColorDefaultsToBlack() throws {
    let node = try iconNode(["icon": ["name": "lucide/house"]])
    #expect(node.icon == DesignIcon(name: "lucide/house", color: .black))
    #expect(node.name == NodeType.icon.title)
}

@Test func iconRequiresIcon() {
    #expect(failure { _ = try iconNode([:]) } == "Layer i: icon layer is missing icon")
    #expect(failure { _ = try iconNode(["icon": [:]]) } == "Layer i: missing icon.name")
}

@Test func iconRejectsBadName() {
    for name in ["house", "foo/house", "lucide/", "/house", ""] {
        #expect(failure { _ = try iconNode(["icon": ["name": name]]) }
                == "Layer i: icon.name must be <library>/<name> with library one of sf, material-outlined, material-rounded, material-sharp, weui, lucide; got \(name)")
    }
}

@Test func iconRejectsUnsupportedFields() {
    let fields: [String: Any] = ["cornerRadius": 4, "children": [], "layout": [:], "clipsContent": false,
                                 "text": ["content": "x"], "image": ["data": ""]]
    for (key, value) in fields {
        #expect(failure { _ = try iconNode(["icon": ["name": "lucide/house"], key: value]) } == "Layer i: icon does not support \(key)")
    }
}

@Test func iconAcceptsGenericFields() throws {
    let node = try iconNode(["icon": ["name": "sf/heart.fill"], "opacity": 0.5, "fill": "#EEEEEE",
                             "animation": ["type": "pulse"], "interaction": ["action": "back"]])
    #expect(node.opacity == 0.5)
    #expect(node.animation != nil)
    #expect(node.interaction == .back)
}

@Test func unknownIconNameStillDecodes() throws {
    let json = #"{"format":"fudehand.design","version":5,"nodes":[{"id":"i","type":"icon","name":"","x":0,"y":0,"width":24,"height":24,"icon":{"name":"sf/not.a.real.symbol"}}]}"#
    #expect(try DesignDocument.decode(Data(json.utf8)).nodes[0].icon?.name == "sf/not.a.real.symbol")
}

@Test func iconPatchMergesColor() throws {
    let red = try DesignColor(hex: "#FF0000")
    var node = try iconNode(["icon": ["name": "lucide/house"]])
    try DesignJSON.apply(["icon": ["color": "#FF0000"]], to: &node)
    #expect(node.icon == DesignIcon(name: "lucide/house", color: red))
    try DesignJSON.apply(["icon": ["name": "weui/success"]], to: &node)
    #expect(node.icon?.name == "weui/success")
    #expect(node.icon?.color == red)
}

@Test func iconLibraryParsesNames() {
    #expect(IconLibrary.parse("material-sharp/search")! == (IconLibrary.materialSharp, "search"))
    #expect(IconLibrary.parse("sf/square.and.arrow.up")! == (IconLibrary.sf, "square.and.arrow.up"))
    #expect(IconLibrary.parse("lucide") == nil)
    #expect(IconLibrary.allCases.map(\.rawValue) == ["sf", "material-outlined", "material-rounded", "material-sharp", "weui", "lucide"])
}

@Test func version5IsWrittenAndVersion4Opens() throws {
    #expect(DesignDocument.formatVersion == 5)
    let json = #"{"format":"fudehand.design","version":4,"nodes":[{"id":"r","type":"rectangle","name":"","x":0,"y":0,"width":1,"height":1}]}"#
    #expect(try DesignDocument.decode(Data(json.utf8)).nodes.count == 1)
}
