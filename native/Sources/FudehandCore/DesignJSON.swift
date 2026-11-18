import Foundation
import ImageIO

/// The single conversion and validation between design nodes and JSON: reading project files and the Agent creating and updating layers all go through here.
public enum DesignJSON {
    static let nodeKeys: Set<String> = ["id", "type", "name", "x", "y", "width", "height", "visible", "locked", "opacity", "fill",
                                        "stroke", "cornerRadius", "clipsContent", "sizing", "text", "image", "layout", "interaction", "children"]
    /// The nested objects that are merged field by field on update. `interaction` is not one of them: an update replaces it whole.
    static let nestedKeys: Set<String> = ["stroke", "sizing", "text", "image", "layout", "padding"]

    /// The upper limit on the absolute value of every numeric field.
    public static let maximumMagnitude = 1_000_000.0

    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    // MARK: Reading

    /// Reads a JSON object field by field; error messages carry the layer id and the field path.
    struct Reader {
        let object: [String: Any]
        let owner: String
        let path: String

        func fail(_ text: String) -> DesignError { DesignError("Layer \(owner): \(text)") }
        func name(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

        func checkKeys(_ allowed: Set<String>) throws {
            if let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first { throw fail("unsupported field \(name(unknown))") }
        }

        func value(_ key: String) -> Any? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            return value
        }

        func number(_ key: String, default fallback: Double? = nil, min: Double? = nil, max: Double? = nil) throws -> Double {
            guard let raw = value(key) else {
                if let fallback { return fallback }
                throw fail("missing \(name(key))")
            }
            guard let number = raw as? NSNumber, !DesignJSON.isBool(number), number.doubleValue.isFinite else {
                throw fail("\(name(key)) must be a number")
            }
            let result = number.doubleValue
            // Coordinates and sizes are limited to a sane range, so extreme values do not overflow rendering and UI conversions.
            guard abs(result) <= DesignJSON.maximumMagnitude else { throw fail("\(name(key)) is out of range (absolute value must not exceed 1000000)") }
            if let min, result < min { throw fail(min == 0 ? "\(name(key)) must not be negative" : "\(name(key)) must not be less than \(format(min))") }
            if let max, result > max { throw fail("\(name(key)) must not be greater than \(format(max))") }
            return result
        }

        func integer(_ key: String, default fallback: Double? = nil, min: Double? = nil, max: Double? = nil) throws -> Int {
            let result = try number(key, default: fallback, min: min, max: max)
            guard result == result.rounded() else { throw fail("\(name(key)) must be an integer") }
            return Int(result)
        }

        func optionalNumber(_ key: String, min: Double) throws -> Double? {
            value(key) == nil ? nil : try number(key, min: min)
        }

        func bool(_ key: String, default fallback: Bool) throws -> Bool {
            guard let raw = value(key) else { return fallback }
            guard let number = raw as? NSNumber, DesignJSON.isBool(number) else { throw fail("\(name(key)) must be true or false") }
            return number.boolValue
        }

        func string(_ key: String, default fallback: String? = nil) throws -> String {
            guard let raw = value(key) else {
                if let fallback { return fallback }
                throw fail("missing \(name(key))")
            }
            guard let text = raw as? String else { throw fail("\(name(key)) must be a string") }
            return text
        }

        func choice<T: RawRepresentable & CaseIterable>(_ key: String, default fallback: T) throws -> T where T.RawValue == String {
            guard value(key) != nil else { return fallback }
            let text = try string(key)
            guard let result = T(rawValue: text) else {
                throw fail("\(name(key)) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", ")); got \(text)")
            }
            return result
        }

        func color(_ key: String, default fallback: DesignColor? = nil) throws -> DesignColor? {
            guard value(key) != nil else { return fallback }
            do { return try DesignColor(hex: try string(key)) } catch let error as DesignError {
                throw fail("\(name(key)) \(error.message)")
            }
        }

        func child(_ key: String) throws -> Reader? {
            guard let raw = value(key) else { return nil }
            guard let object = raw as? [String: Any] else { throw fail("\(name(key)) must be an object") }
            return Reader(object: object, owner: owner, path: name(key))
        }

        private func format(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

    /// Builds and validates a node (with its children) from a JSON object. `id` must already be present.
    public static func node(from value: Any) throws -> DesignNode {
        guard let object = value as? [String: Any] else { throw DesignError("Layer must be a JSON object") }
        guard let raw = object["id"] else { throw DesignError("Layer is missing id") }
        guard let id = raw as? String, !id.isEmpty else { throw DesignError("Layer id must be a non-empty string") }
        let reader = Reader(object: object, owner: id, path: "")
        try reader.checkKeys(nodeKeys)
        let typeName = try reader.string("type")
        guard let type = NodeType(rawValue: typeName) else {
            throw reader.fail("unknown type \(typeName); must be one of \(NodeType.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        func unsupported(_ key: String, _ allowed: Bool) throws {
            if !allowed, reader.value(key) != nil { throw reader.fail("\(type.rawValue) does not support \(key)") }
        }
        try unsupported("children", type.hasChildren)
        try unsupported("cornerRadius", type.hasCornerRadius)
        try unsupported("clipsContent", type == .frame)
        try unsupported("layout", type == .frame)
        try unsupported("text", type == .text)
        try unsupported("image", type == .image)

        var node = DesignNode(id: id, type: type, name: try reader.string("name", default: type.title),
                              x: try reader.number("x", default: 0), y: try reader.number("y", default: 0),
                              width: try reader.number("width", default: 100, min: 0),
                              height: try reader.number("height", default: 100, min: 0))
        node.visible = try reader.bool("visible", default: true)
        node.locked = try reader.bool("locked", default: false)
        node.opacity = try reader.number("opacity", default: 1, min: 0, max: 1)
        node.fill = try reader.color("fill")
        if let stroke = try reader.child("stroke") {
            try stroke.checkKeys(["color", "width"])
            node.stroke = DesignStroke(color: try stroke.color("color", default: .black)!, width: try stroke.number("width", default: 1, min: 0))
        }
        node.cornerRadius = try reader.number("cornerRadius", default: 0, min: 0)
        node.clipsContent = try reader.bool("clipsContent", default: true)
        if let sizing = try reader.child("sizing") {
            try sizing.checkKeys(["horizontal", "vertical"])
            node.sizing = Sizing(horizontal: try sizing.choice("horizontal", default: .fixed), vertical: try sizing.choice("vertical", default: .fixed))
        }
        if type == .text {
            guard let text = try reader.child("text") else { throw reader.fail("text layer is missing text") }
            try text.checkKeys(["content", "fontSize", "fontWeight", "fontFamily", "color", "align", "lineHeight", "autoResize"])
            let family = try text.string("fontFamily", default: "")
            node.text = DesignText(content: try text.string("content", default: ""),
                                   fontSize: try text.number("fontSize", default: 16, min: 1),
                                   fontWeight: try text.integer("fontWeight", default: 400, min: 100, max: 900),
                                   fontFamily: family.isEmpty ? nil : family,
                                   color: try text.color("color", default: .black)!,
                                   align: try text.choice("align", default: .left),
                                   lineHeight: try text.optionalNumber("lineHeight", min: 0.1),
                                   autoResize: try text.choice("autoResize", default: .widthAndHeight))
        }
        if type == .image {
            guard let image = try reader.child("image") else { throw reader.fail("image layer is missing image") }
            try image.checkKeys(["data", "fit"])
            let encoded = try image.string("data")
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), isImage(data) else {
                throw reader.fail("image.data must be a base64-encoded PNG, JPEG, or SVG")
            }
            node.image = DesignImage(data: data, fit: try image.choice("fit", default: .fill))
        }
        if let layout = try reader.child("layout") {
            try layout.checkKeys(["direction", "spacing", "padding", "align", "crossAlign"])
            var padding = EdgeInsets()
            if let inset = try layout.child("padding") {
                try inset.checkKeys(["top", "right", "bottom", "left"])
                padding = EdgeInsets(top: try inset.number("top", default: 0, min: 0), right: try inset.number("right", default: 0, min: 0),
                                     bottom: try inset.number("bottom", default: 0, min: 0), left: try inset.number("left", default: 0, min: 0))
            }
            node.layout = AutoLayout(direction: try layout.choice("direction", default: .vertical),
                                     spacing: try layout.number("spacing", default: 0),
                                     padding: padding,
                                     align: try layout.choice("align", default: .start),
                                     crossAlign: try layout.choice("crossAlign", default: .start))
        }
        if let interaction = try reader.child("interaction") {
            node.interaction = try self.interaction(interaction)
        }
        if let children = reader.value("children") {
            guard let list = children as? [Any] else { throw reader.fail("children must be an array") }
            node.children = try list.map(node(from:))
        }
        return node
    }

    static func interaction(_ reader: Reader) throws -> DesignInteraction {
        let action = try reader.string("action")
        switch action {
        case "back":
            try reader.checkKeys(["action"])
            return .back
        case "navigate":
            try reader.checkKeys(["action", "destination", "transition"])
            let destination = try reader.string("destination")
            guard !destination.isEmpty else { throw reader.fail("\(reader.name("destination")) must be a non-empty frame id") }
            var transition = PrototypeTransition()
            if let value = try reader.child("transition") {
                try value.checkKeys(["type", "duration", "easing"])
                transition = PrototypeTransition(type: try value.choice("type", default: .none),
                                                 duration: try value.number("duration", default: 0.3, min: 0, max: PrototypeTransition.maximumDuration),
                                                 easing: try value.choice("easing", default: .easeOut))
            }
            return .navigate(destination: destination, transition: transition)
        default:
            throw reader.fail("\(reader.name("action")) must be one of navigate, back; got \(action)")
        }
    }

    static func isImage(_ data: Data) -> Bool {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 { return true }
        return isSVG(data)
    }

    /// Whether the data is well-formed XML whose root element is `svg`. ImageIO does not read SVG, and drawing it needs AppKit, so this
    /// only checks the structure: an SVG the system cannot draw passes and shows up blank.
    public static func isSVG(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        // Reports the local name, so a root written as `<svg:svg xmlns:svg="…">` is recognized too.
        parser.shouldProcessNamespaces = true
        let root = RootElement()
        parser.delegate = root
        return parser.parse() && root.name == "svg"
    }

    private final class RootElement: NSObject, XMLParserDelegate {
        var name: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == nil { name = elementName }
        }
    }

    // MARK: Writing

    /// The JSON form of a node; default values are omitted. When `includeImageData` is false, image data is replaced by its byte count, for the Agent to read.
    public static func object(_ node: DesignNode, includeImageData: Bool, includeChildren: Bool = true) -> [String: Any] {
        var object: [String: Any] = ["id": node.id, "type": node.type.rawValue, "name": node.name,
                                     "x": node.x, "y": node.y, "width": node.width, "height": node.height]
        if !node.visible { object["visible"] = false }
        if node.locked { object["locked"] = true }
        if node.opacity != 1 { object["opacity"] = node.opacity }
        if let fill = node.fill { object["fill"] = fill.hex }
        if let stroke = node.stroke { object["stroke"] = ["color": stroke.color.hex, "width": stroke.width] }
        if node.type.hasCornerRadius, node.cornerRadius != 0 { object["cornerRadius"] = node.cornerRadius }
        if node.type == .frame, !node.clipsContent { object["clipsContent"] = false }
        if node.sizing != .fixed { object["sizing"] = ["horizontal": node.sizing.horizontal.rawValue, "vertical": node.sizing.vertical.rawValue] }
        if let text = node.text {
            var value: [String: Any] = ["content": text.content, "fontSize": text.fontSize, "fontWeight": text.fontWeight,
                                        "color": text.color.hex, "align": text.align.rawValue, "autoResize": text.autoResize.rawValue]
            if let family = text.fontFamily { value["fontFamily"] = family }
            if let lineHeight = text.lineHeight { value["lineHeight"] = lineHeight }
            object["text"] = value
        }
        if let image = node.image {
            object["image"] = ["data": includeImageData ? image.data.base64EncodedString() : "<\(image.data.count) bytes>",
                               "fit": image.fit.rawValue]
        }
        if let layout = node.layout {
            object["layout"] = ["direction": layout.direction.rawValue, "spacing": layout.spacing,
                                "padding": ["top": layout.padding.top, "right": layout.padding.right,
                                            "bottom": layout.padding.bottom, "left": layout.padding.left],
                                "align": layout.align.rawValue, "crossAlign": layout.crossAlign.rawValue]
        }
        switch node.interaction {
        case .navigate(let destination, let transition):
            object["interaction"] = ["action": "navigate", "destination": destination,
                                     "transition": ["type": transition.type.rawValue, "duration": transition.duration, "easing": transition.easing.rawValue]]
        case .back: object["interaction"] = ["action": "back"]
        case nil: break
        }
        if includeChildren, !node.children.isEmpty {
            object["children"] = node.children.map { self.object($0, includeImageData: includeImageData) }
        }
        return object
    }

    // MARK: Patching

    /// Applies a partial field patch to a node: nested objects are merged field by field, and null clears a field; the whole node is validated again, and on failure the node is unchanged.
    public static func apply(_ changes: [String: Any], to node: inout DesignNode) throws {
        for key in ["id", "type", "children"] where changes[key] != nil {
            throw DesignError("Layer \(node.id): cannot change \(key)")
        }
        var object = self.object(node, includeImageData: true, includeChildren: false)
        merge(changes, into: &object)
        var next = try self.node(from: object)
        next.children = node.children
        node = next
    }

    static func merge(_ changes: [String: Any], into object: inout [String: Any]) {
        for (key, value) in changes {
            if value is NSNull {
                object.removeValue(forKey: key)
            } else if nestedKeys.contains(key), let patch = value as? [String: Any], var current = object[key] as? [String: Any] {
                merge(patch, into: &current)
                object[key] = current
            } else {
                object[key] = value
            }
        }
    }
}
