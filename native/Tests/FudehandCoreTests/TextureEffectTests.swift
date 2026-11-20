import Foundation
import Testing
import FudehandCore

private func node(_ object: [String: Any]) throws -> DesignNode {
    try DesignJSON.node(from: ["id": "n", "type": "rectangle"].merging(object) { $1 })
}

private func message(_ object: [String: Any]) -> String? {
    do { _ = try node(object); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="4" height="4"/></svg>"#.utf8)

@Test func textureReadsWithDefaults() throws {
    let read = try node(["effects": [["type": "texture", "image": ["data": svg.base64EncodedString()]],
                                     ["type": "texture", "image": ["data": svg.base64EncodedString()], "size": 32, "opacity": 0.5,
                                      "blend": "soft-light", "visible": false]]])
    #expect(read.effects == [
        DesignEffect(type: .texture, texture: svg),
        DesignEffect(type: .texture, visible: false, size: 32, texture: svg, opacity: 0.5, blend: .softLight),
    ])
    let plain = DesignEffect(type: .texture, texture: svg)
    #expect(plain.size == 64 && plain.opacity == 1 && plain.blend == .normal)
}

@Test func textureRoundTripsThroughJSONWithOnlyItsFields() throws {
    var original = DesignNode(id: "n", type: .ellipse)
    original.effects = [DesignEffect(type: .texture, size: 16, texture: svg, opacity: 0.4, blend: .multiply)]
    let object = DesignJSON.object(original, includeImageData: true)
    let effects = try #require(object["effects"] as? [[String: Any]])
    #expect(Set(effects[0].keys) == ["type", "image", "size", "opacity", "blend"])
    #expect(effects[0]["blend"] as? String == "multiply")
    #expect(try DesignJSON.node(from: object) == original)
    // For the Agent, the image data is replaced by its byte count, like an image layer's.
    let summary = DesignJSON.object(original, includeImageData: false)
    #expect(((summary["effects"] as? [[String: Any]])?[0]["image"] as? [String: Any])?["data"] as? String == "<\(svg.count) bytes>")
}

@Test func textureIsValidated() {
    let image = ["data": svg.base64EncodedString()]
    #expect(message(["effects": [["type": "texture"]]]) == "Layer n: effects[0] texture is missing image")
    #expect(message(["effects": [["type": "texture", "image": ["data": "bm90IGFuIGltYWdl"]]]])
            == "Layer n: effects[0].image.data must be a base64-encoded PNG, JPEG, or SVG")
    #expect(message(["effects": [["type": "texture", "image": ["data": svg.base64EncodedString(), "fit": "fill"]]]])
            == "Layer n: unsupported field effects[0].image.fit")
    #expect(message(["effects": [["type": "texture", "image": image, "size": 2]]]) == "Layer n: effects[0].size must not be less than 4")
    #expect(message(["effects": [["type": "texture", "image": image, "size": 2000]]]) == "Layer n: effects[0].size must not be greater than 1024")
    #expect(message(["effects": [["type": "texture", "image": image, "opacity": 2]]]) == "Layer n: effects[0].opacity must not be greater than 1")
    #expect(message(["effects": [["type": "texture", "image": image, "blend": "darken"]]])
            == "Layer n: effects[0].blend must be one of normal, multiply, screen, overlay, soft-light; got darken")
    #expect(message(["effects": [["type": "texture", "image": image, "density": 1]]]) == "Layer n: unsupported field effects[0].density")
    #expect(message(["effects": [["type": "noise", "image": image]]]) == "Layer n: unsupported field effects[0].image")
    for type in [NodeType.frame, .rectangle, .ellipse] { #expect(EffectType.texture.supports(type)) }
    for type in [NodeType.text, .image, .icon, .group] { #expect(!EffectType.texture.supports(type)) }
}

@Test func anUpdateCanSendATextureBackAsItsByteCount() throws {
    // design_get_node shows a texture's image as "<N bytes>"; effects are replaced whole, so an Agent changing another effect
    // sends the texture back with that placeholder, and it keeps its image.
    var target = try node(["effects": [["type": "drop-shadow"], ["type": "texture", "image": ["data": svg.base64EncodedString()]]]])
    let shown = try #require(DesignJSON.object(target, includeImageData: false)["effects"] as? [[String: Any]])
    var changed = shown
    changed[0]["y"] = 12
    changed[1]["size"] = 16
    try DesignJSON.apply(["effects": changed], to: &target)
    #expect(target.effects[0].y == 12)
    #expect(target.effects[1].texture == svg && target.effects[1].size == 16)
    // The placeholder only stands for the texture at the same place in the list.
    let moved = [shown[1], shown[0]]
    #expect(throws: DesignError.self) { try DesignJSON.apply(["effects": moved], to: &target) }
}
