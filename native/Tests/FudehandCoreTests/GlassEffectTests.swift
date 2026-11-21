import Foundation
import Testing
import FudehandCore

private func node(_ object: [String: Any]) throws -> DesignNode {
    try DesignJSON.node(from: ["id": "n", "type": "rectangle"].merging(object) { $1 })
}

private func message(_ object: [String: Any]) -> String? {
    do { _ = try node(object); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

@Test func glassReadsWithDefaults() throws {
    let read = try node(["effects": [["type": "glass"]]])
    #expect(read.effects == [DesignEffect(type: .glass)])
    let plain = DesignEffect(type: .glass)
    #expect(plain.radius == 20 && plain.saturation == 1.4 && plain.color.hex == "#FFFFFF33" && plain.highlight == 0.5)
    let set = try node(["effects": [["type": "glass", "radius": 40, "saturation": 0.5, "tint": "#00000080", "highlight": 0, "visible": false]]])
    #expect(set.effects == [DesignEffect(type: .glass, visible: false, color: DesignColor(r: 0, g: 0, b: 0, a: 128.0 / 255), radius: 40,
                                         saturation: 0.5, highlight: 0)])
}

@Test func glassRoundTripsThroughJSONWithOnlyItsFields() throws {
    var original = DesignNode(id: "n", type: .frame)
    original.effects = [DesignEffect(type: .glass, radius: 30, saturation: 1, highlight: 0.8)]
    let object = DesignJSON.object(original, includeImageData: true)
    let effects = try #require(object["effects"] as? [[String: Any]])
    #expect(Set(effects[0].keys) == ["type", "radius", "saturation", "tint", "highlight"])
    #expect(effects[0]["tint"] as? String == "#FFFFFF33")
    #expect(try DesignJSON.node(from: object) == original)
}

@Test func glassIsValidated() {
    #expect(message(["effects": [["type": "glass", "color": "#FFFFFF"]]]) == "Layer n: unsupported field effects[0].color")
    #expect(message(["effects": [["type": "glass", "saturation": 3]]]) == "Layer n: effects[0].saturation must not be greater than 2")
    #expect(message(["effects": [["type": "glass", "highlight": -0.1]]]) == "Layer n: effects[0].highlight must not be negative")
    #expect(message(["effects": [["type": "glass", "radius": 251]]]) == "Layer n: effects[0].radius must not be greater than 250")
    #expect(message(["effects": [["type": "glass"], ["type": "glass"]]]) == "Layer n: a layer takes at most one glass effect")
    // Glass already blurs what is under the layer; a background blur on top would blur it twice.
    #expect(message(["effects": [["type": "background-blur"], ["type": "glass"]]])
            == "Layer n: glass and background-blur cannot be on the same layer")
    // Hidden ones count too, so showing one later cannot make an invalid list.
    #expect(message(["effects": [["type": "glass", "visible": false], ["type": "glass"]]]) == "Layer n: a layer takes at most one glass effect")
    for type in [NodeType.frame, .rectangle, .ellipse] { #expect(EffectType.glass.supports(type)) }
    for type in [NodeType.text, .image, .icon, .group] { #expect(!EffectType.glass.supports(type)) }
}
