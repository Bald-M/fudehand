import Foundation
import Testing
import FudehandCore

private func node(_ object: [String: Any]) throws -> DesignNode {
    try DesignJSON.node(from: ["id": "n", "type": "rectangle"].merging(object) { $1 })
}

private func message(_ object: [String: Any]) -> String? {
    do { _ = try node(object); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

@Test func noiseReadsWithDefaults() throws {
    let read = try node(["effects": [["type": "noise"], ["type": "noise", "color": "#FFFFFF80", "size": 2, "density": 0.8, "seed": 7,
                                                         "visible": false]]])
    #expect(read.effects == [
        DesignEffect(type: .noise),
        DesignEffect(type: .noise, visible: false, color: DesignColor(r: 1, g: 1, b: 1, a: 128.0 / 255), size: 2, density: 0.8, seed: 7),
    ])
    let plain = DesignEffect(type: .noise)
    #expect(plain.color.hex == "#00000033" && plain.size == 1 && plain.density == 0.5 && plain.seed == 0)
}

@Test func noiseRoundTripsThroughJSONWithOnlyItsFields() throws {
    var original = DesignNode(id: "n", type: .frame)
    original.effects = [DesignEffect(type: .noise, size: 3, density: 0.25, seed: 42)]
    let object = DesignJSON.object(original, includeImageData: true)
    let effects = try #require(object["effects"] as? [[String: Any]])
    #expect(Set(effects[0].keys) == ["type", "color", "size", "density", "seed"])
    #expect(try DesignJSON.node(from: object) == original)
}

@Test func noiseIsValidated() {
    #expect(message(["effects": [["type": "noise", "radius": 4]]]) == "Layer n: unsupported field effects[0].radius")
    #expect(message(["effects": [["type": "noise", "size": 0.25]]]) == "Layer n: effects[0].size must not be less than 0.5")
    #expect(message(["effects": [["type": "noise", "size": 9]]]) == "Layer n: effects[0].size must not be greater than 8")
    #expect(message(["effects": [["type": "noise", "density": 1.5]]]) == "Layer n: effects[0].density must not be greater than 1")
    #expect(message(["effects": [["type": "noise", "seed": 1.5]]]) == "Layer n: effects[0].seed must be an integer")
    #expect(message(["effects": [["type": "noise", "seed": -1]]]) == "Layer n: effects[0].seed must not be negative")
    // Noise paints over a layer's area, so text, image, and icon layers do not take it.
    for (type, content) in [("text", ["text": ["content": "A"]]), ("icon", ["icon": ["name": "sf/star"]])] {
        let error = message(["type": type, "effects": [["type": "noise"]]].merging(content) { $1 })
        #expect(error == "Layer n: \(type) does not support noise effects", "\(type): \(error ?? "accepted")")
    }
    for type in [NodeType.text, .image, .icon, .group] { #expect(!EffectType.noise.supports(type)) }
    for type in [NodeType.frame, .rectangle, .ellipse] { #expect(EffectType.noise.supports(type)) }
    for type in NodeType.allCases where type != .group { #expect(EffectType.dropShadow.supports(type)) }
}

@Test func noiseTileIsDeterministicAndFollowsDensity() {
    let side = NoiseTile.side
    let tile = NoiseTile.cells(density: 0.5, seed: 0)
    #expect(tile.count == side * side)
    #expect(tile == NoiseTile.cells(density: 0.5, seed: 0))
    #expect(tile != NoiseTile.cells(density: 0.5, seed: 1))
    let drawn = Double(tile.filter { $0 > 0 }.count) / Double(tile.count)
    #expect(abs(drawn - 0.5) < 0.02, "share of grains: \(drawn)")
    #expect(NoiseTile.cells(density: 0, seed: 0).allSatisfy { $0 == 0 })
    #expect(NoiseTile.cells(density: 1, seed: 0).allSatisfy { $0 > 0 })
    // A denser tile keeps the sparser one's grains, so dragging density adds grains rather than reshuffling them.
    let denser = NoiseTile.cells(density: 0.8, seed: 0)
    #expect(zip(tile, denser).allSatisfy { $0 == 0 || $0 == $1 })
}
