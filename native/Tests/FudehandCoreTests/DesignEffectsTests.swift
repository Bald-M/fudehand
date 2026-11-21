import Foundation
import Testing
import FudehandCore

private func node(_ object: [String: Any]) throws -> DesignNode {
    try DesignJSON.node(from: ["id": "n", "type": "rectangle"].merging(object) { $1 })
}

private func message(_ object: [String: Any]) -> String? {
    do { _ = try node(object); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

@Test func effectsReadWithDefaults() throws {
    let read = try node(["effects": [["type": "drop-shadow"], ["type": "inner-shadow", "color": "#FF000080", "x": 2, "y": -3, "radius": 8,
                                                                 "spread": -1, "visible": false],
                                     ["type": "layer-blur"], ["type": "background-blur", "radius": 20]]])
    #expect(read.effects == [
        DesignEffect(type: .dropShadow),
        DesignEffect(type: .innerShadow, visible: false, color: DesignColor(r: 1, g: 0, b: 0, a: 128.0 / 255), x: 2, y: -3, radius: 8, spread: -1),
        DesignEffect(type: .layerBlur),
        DesignEffect(type: .backgroundBlur, radius: 20),
    ])
    #expect(DesignEffect(type: .dropShadow).color.hex == "#00000040")
    #expect(DesignEffect(type: .dropShadow).y == 4 && DesignEffect(type: .dropShadow).radius == 4)
}

@Test func effectsRoundTripThroughJSON() throws {
    var original = DesignNode(id: "n", type: .ellipse)
    original.effects = [DesignEffect(type: .dropShadow, x: 1, y: 2, radius: 3, spread: 4), DesignEffect(type: .backgroundBlur, visible: false, radius: 12)]
    let object = DesignJSON.object(original, includeImageData: true)
    let effects = try #require(object["effects"] as? [[String: Any]])
    #expect(effects[0]["type"] as? String == "drop-shadow" && effects[0]["color"] as? String == "#00000040" && effects[0]["visible"] == nil)
    // A blur writes only its radius.
    #expect(Set(effects[1].keys) == ["type", "visible", "radius"])
    #expect(try DesignJSON.node(from: object) == original)
    #expect(DesignJSON.object(DesignNode(id: "n", type: .ellipse), includeImageData: true)["effects"] == nil)
}

@Test func effectsAreValidated() {
    #expect(message(["effects": ["type": "drop-shadow"]]) == "Layer n: effects must be an array of objects")
    #expect(message(["effects": [3]]) == "Layer n: effects must be an array of objects")
    #expect(message(["effects": [["color": "#000000"]]]) == "Layer n: missing effects[0].type")
    #expect(message(["effects": [["type": "glow"]]])
            == "Layer n: effects[0].type must be one of drop-shadow, inner-shadow, layer-blur, background-blur, noise, texture, glass, shader, transform-3d, perspective; got glow")
    #expect(message(["effects": [["type": "layer-blur"], ["type": "layer-blur", "x": 2]]]) == "Layer n: unsupported field effects[1].x")
    #expect(message(["effects": [["type": "drop-shadow", "radius": -1]]]) == "Layer n: effects[0].radius must not be negative")
    #expect(message(["effects": [["type": "background-blur", "radius": 251]]]) == "Layer n: effects[0].radius must not be greater than 250")
    #expect(message(["effects": [["type": "drop-shadow", "color": "red"]]])?.hasPrefix("Layer n: effects[0].color Color must be") == true)
    #expect(message(["type": "group", "effects": [["type": "layer-blur"]]]) == "Layer n: group does not support effects")
    for type in NodeType.allCases where type != .group {
        #expect(type.hasEffects)
    }
}

@Test func effectsAreReplacedWholeOnUpdateAndClearedByNull() throws {
    var target = try node(["effects": [["type": "drop-shadow"], ["type": "layer-blur"]]])
    try DesignJSON.apply(["effects": [["type": "background-blur", "radius": 10]]], to: &target)
    #expect(target.effects == [DesignEffect(type: .backgroundBlur, radius: 10)])
    try DesignJSON.apply(["effects": NSNull()], to: &target)
    #expect(target.effects.isEmpty)
}

@Test func filesWithEffectsUseTheCurrentFormatVersion() throws {
    #expect(DesignDocument.formatVersion >= 9)
    var document = DesignDocument(nodes: [DesignNode(id: "r", type: .rectangle)])
    document.nodes[0].effects = [DesignEffect(type: .innerShadow)]
    #expect(try DesignDocument.decode(try document.encoded()) == document)
}
