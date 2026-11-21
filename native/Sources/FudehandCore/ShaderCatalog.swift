/// A value of a shader parameter.
public enum ShaderValue: Equatable, Sendable {
    case number(Double)
    case color(DesignColor)
}

/// One parameter a shader declares: its name, what kind of value it takes, its range (numbers), and its default.
public struct ShaderParameter: Sendable {
    public let name: String
    /// The English label; the properties panel localizes it.
    public let label: String
    public let range: ClosedRange<Double>?
    public let defaultValue: ShaderValue

    static func number(_ name: String, _ label: String, _ range: ClosedRange<Double>, default value: Double) -> ShaderParameter {
        ShaderParameter(name: name, label: label, range: range, defaultValue: .number(value))
    }

    static func color(_ name: String, _ label: String, default hex: String) -> ShaderParameter {
        ShaderParameter(name: name, label: label, range: nil, defaultValue: .color(try! DesignColor(hex: hex)))
    }

    public var isColor: Bool { if case .color = defaultValue { return true } else { return false } }
}

/// A shader that ships with Fudehand. Only these can be drawn: a file or an Agent names one by `id` and sets its declared
/// parameters, never shader code (ADR 0012). The App renders each one with a Metal function of the same name.
public struct ShaderEntry: Sendable {
    public let id: String
    /// The English name; the properties panel localizes it.
    public let name: String
    public let summary: String
    public let parameters: [ShaderParameter]

    public func parameter(_ name: String) -> ShaderParameter? { parameters.first { $0.name == name } }

    /// Every parameter at its default.
    public var defaults: [String: ShaderValue] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.defaultValue) })
    }
}

public enum ShaderCatalog {
    public static let all: [ShaderEntry] = [
        ShaderEntry(id: "waves", name: "Waves", summary: "Soft bands blending two colors, gently curved", parameters: [
            .number("scale", "Scale", 8...800, default: 96),
            .number("angle", "Angle", -180...180, default: 30),
            .color("colorA", "First color", default: "#6C63FF"),
            .color("colorB", "Second color", default: "#FF8A65"),
        ]),
        ShaderEntry(id: "mesh-gradient", name: "Mesh Gradient", summary: "A smooth blend between four corner colors", parameters: [
            .color("topLeft", "Top left", default: "#FF9A8B"),
            .color("topRight", "Top right", default: "#FFD86F"),
            .color("bottomLeft", "Bottom left", default: "#6A82FB"),
            .color("bottomRight", "Bottom right", default: "#3DDBD9"),
        ]),
        ShaderEntry(id: "halftone", name: "Halftone", summary: "Dots on a grid that grow from nothing to touching across the layer", parameters: [
            .number("size", "Dot spacing", 4...64, default: 12),
            .number("angle", "Angle", -180...180, default: 45),
            .color("color", "Dot color", default: "#1B2A4A"),
        ]),
    ]

    public static func entry(_ id: String) -> ShaderEntry? { all.first { $0.id == id } }

    /// The catalog as the Agent reads it (`design_list_shaders`).
    public static var object: [String: Any] {
        ["shaders": all.map { entry -> [String: Any] in
            ["id": entry.id, "name": entry.name, "description": entry.summary,
             "params": entry.parameters.map { parameter -> [String: Any] in
                 var value: [String: Any] = ["name": parameter.name, "kind": parameter.isColor ? "color" : "number"]
                 switch parameter.defaultValue {
                 case .number(let number):
                     value["default"] = number
                     if let range = parameter.range { value["min"] = range.lowerBound; value["max"] = range.upperBound }
                 case .color(let color): value["default"] = color.hex
                 }
                 return value
             }]
        }]
    }
}
