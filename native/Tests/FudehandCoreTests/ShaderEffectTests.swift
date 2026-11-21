import Foundation
import Testing
import FudehandCore

private func node(_ object: [String: Any]) throws -> DesignNode {
    try DesignJSON.node(from: ["id": "n", "type": "rectangle"].merging(object) { $1 })
}

private func message(_ object: [String: Any]) -> String? {
    do { _ = try node(object); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

@Test func shaderReadsWithEveryParameterFilledIn() throws {
    let read = try node(["effects": [["type": "shader", "shader": "waves", "params": ["scale": 40, "colorA": "#000000"]]]])
    let effect = try #require(read.effects.first)
    #expect(effect.shader == "waves" && effect.opacity == 1 && effect.blend == .normal)
    #expect(effect.shaderParams["scale"] == .number(40))
    #expect(effect.shaderParams["colorA"] == .color(DesignColor(r: 0, g: 0, b: 0)))
    // Parameters left out take the catalog's defaults, so two effects that draw the same compare equal.
    #expect(effect.shaderParams["angle"] == .number(30))
    #expect(effect.shaderParams.count == ShaderCatalog.entry("waves")?.parameters.count)
    #expect(DesignEffect(type: .shader).shader == "waves" && DesignEffect(type: .shader).shaderParams == ShaderCatalog.entry("waves")?.defaults)
}

@Test func shaderRoundTripsThroughJSON() throws {
    var original = DesignNode(id: "n", type: .frame)
    var effect = DesignEffect(type: .shader, opacity: 0.5, blend: .overlay)
    effect.shader = "halftone"
    effect.shaderParams = try #require(ShaderCatalog.entry("halftone")?.defaults)
    effect.shaderParams["size"] = .number(20)
    original.effects = [effect]
    let object = DesignJSON.object(original, includeImageData: true)
    let effects = try #require(object["effects"] as? [[String: Any]])
    #expect(Set(effects[0].keys) == ["type", "shader", "params", "opacity", "blend"])
    #expect((effects[0]["params"] as? [String: Any])?["color"] as? String == "#1B2A4A")
    #expect(try DesignJSON.node(from: object) == original)
}

@Test func shaderIsValidatedAgainstTheCatalog() {
    #expect(message(["effects": [["type": "shader"]]]) == "Layer n: missing effects[0].shader")
    #expect(message(["effects": [["type": "shader", "shader": "plasma"]]])
            == "Layer n: effects[0].shader must be one of waves, mesh-gradient, halftone; got plasma")
    #expect(message(["effects": [["type": "shader", "shader": "waves", "params": ["speed": 2]]]])
            == "Layer n: unsupported field effects[0].params.speed")
    #expect(message(["effects": [["type": "shader", "shader": "waves", "params": ["scale": 2]]]])
            == "Layer n: effects[0].params.scale must not be less than 8")
    #expect(message(["effects": [["type": "shader", "shader": "waves", "params": ["colorA": 3]]]])
            == "Layer n: effects[0].params.colorA must be a string")
    #expect(message(["effects": [["type": "shader", "shader": "waves", "params": ["scale": "big"]]]])
            == "Layer n: effects[0].params.scale must be a number")
    #expect(message(["effects": [["type": "shader", "shader": "waves", "code": "kernel void f() {}"]]])
            == "Layer n: unsupported field effects[0].code")
    for type in [NodeType.frame, .rectangle, .ellipse] { #expect(EffectType.shader.supports(type)) }
    for type in [NodeType.text, .image, .icon, .group] { #expect(!EffectType.shader.supports(type)) }
}

@Test func shaderCatalogIsListedForTheAgent() throws {
    let shaders = try #require(ShaderCatalog.object["shaders"] as? [[String: Any]])
    #expect(shaders.map { $0["id"] as? String } == ["waves", "mesh-gradient", "halftone"])
    let scale = try #require((shaders[0]["params"] as? [[String: Any]])?.first)
    #expect(scale["name"] as? String == "scale" && scale["kind"] as? String == "number" && scale["min"] as? Double == 8)
    let color = try #require((shaders[1]["params"] as? [[String: Any]])?.first)
    #expect(color["kind"] as? String == "color" && color["default"] as? String == "#FF9A8B")
}

/// The properties panel localizes catalog names and parameter labels by value, which the literal `L("…")` scan cannot see.
@Test func shaderCatalogNamesAndLabelsAreInEveryTable() {
    let keys = ShaderCatalog.all.flatMap { [$0.name] + $0.parameters.map(\.label) }
    for language in AppLanguage.allCases {
        let table = L10n.table(language)
        for key in keys { #expect(table[key] != nil, "\(language): missing \(key)") }
    }
}
