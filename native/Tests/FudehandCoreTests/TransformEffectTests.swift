import Foundation
import Testing
import FudehandCore

private func node(_ object: [String: Any], type: String = "frame") throws -> DesignNode {
    try DesignJSON.node(from: ["id": "n", "type": type].merging(object) { $1 })
}

private func message(_ object: [String: Any], type: String = "frame") -> String? {
    do { _ = try node(object, type: type); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

@Test func transformAndPerspectiveReadWithDefaults() throws {
    let read = try node(["effects": [["type": "transform-3d"], ["type": "perspective"]]])
    #expect(read.effects == [DesignEffect(type: .transform3D), DesignEffect(type: .perspective)])
    let turn = DesignEffect(type: .transform3D), view = DesignEffect(type: .perspective)
    #expect(turn.rotateX == 0 && turn.rotateY == 0 && turn.translateZ == 0)
    #expect(view.distance == 800 && view.originX == 0.5 && view.originY == 0.5)
    let set = try node(["effects": [["type": "transform-3d", "rotateX": 10, "rotateY": -30, "translateZ": 40],
                                    ["type": "perspective", "distance": 400, "originX": 0, "originY": 1, "visible": false]]])
    #expect(set.effects == [DesignEffect(type: .transform3D, rotateX: 10, rotateY: -30, translateZ: 40),
                            DesignEffect(type: .perspective, visible: false, distance: 400, originX: 0, originY: 1)])
}

@Test func transformAndPerspectiveRoundTripWithOnlyTheirFields() throws {
    var original = DesignNode(id: "n", type: .frame)
    original.effects = [DesignEffect(type: .transform3D, rotateY: 20), DesignEffect(type: .perspective, distance: 600)]
    let object = DesignJSON.object(original, includeImageData: true)
    let effects = try #require(object["effects"] as? [[String: Any]])
    #expect(Set(effects[0].keys) == ["type", "rotateX", "rotateY", "translateZ"])
    #expect(Set(effects[1].keys) == ["type", "distance", "originX", "originY"])
    #expect(try DesignJSON.node(from: object) == original)
}

@Test func transformAndPerspectiveAreValidated() {
    #expect(message(["effects": [["type": "transform-3d", "rotateY": 81]]]) == "Layer n: effects[0].rotateY must not be greater than 80")
    #expect(message(["effects": [["type": "transform-3d", "rotateX": -81]]]) == "Layer n: effects[0].rotateX must not be less than -80")
    #expect(message(["effects": [["type": "transform-3d", "translateZ": 1001]]]) == "Layer n: effects[0].translateZ must not be greater than 1000")
    #expect(message(["effects": [["type": "transform-3d", "radius": 4]]]) == "Layer n: unsupported field effects[0].radius")
    #expect(message(["effects": [["type": "perspective", "distance": 99]]]) == "Layer n: effects[0].distance must not be less than 100")
    #expect(message(["effects": [["type": "perspective", "originX": 1.5]]]) == "Layer n: effects[0].originX must not be greater than 1")
    #expect(message(["effects": [["type": "transform-3d"], ["type": "transform-3d", "visible": false]]])
            == "Layer n: a layer takes at most one transform-3d effect")
    #expect(message(["effects": [["type": "perspective"], ["type": "perspective"]]]) == "Layer n: a layer takes at most one perspective effect")
    // Perspective is how a frame's children are seen, so only frames take it; any layer but a group can be turned.
    #expect(message(["effects": [["type": "perspective"]]], type: "rectangle") == "Layer n: rectangle does not support perspective effects")
    #expect(message(["effects": [["type": "transform-3d"]]], type: "rectangle") == nil)
    #expect(EffectType.perspective.supports(.frame))
    for type in NodeType.allCases where type != .frame { #expect(!EffectType.perspective.supports(type)) }
    for type in NodeType.allCases where type != .group { #expect(EffectType.transform3D.supports(type)) }
    #expect(EffectType.transform3D.isBeta && EffectType.perspective.isBeta && !EffectType.glass.isBeta)
}
