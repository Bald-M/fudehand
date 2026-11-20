import Foundation
import ImageIO

/// The single conversion and validation between design nodes and JSON: reading project files and the Agent creating and updating layers all go through here.
public enum DesignJSON {
    static let nodeKeys: Set<String> = ["id", "type", "name", "x", "y", "width", "height", "visible", "locked", "opacity", "fill",
                                        "stroke", "cornerRadius", "clipsContent", "sizing", "text", "image", "icon", "layout", "interaction", "animation",
                                        "scroll", "fixedOnScroll", "states", "versionSnapshot", "layoutGuides", "children"]
    /// The nested objects that are merged field by field on update. `interaction`, `animation`, `states`, and `text.sequence` are
    /// not among them, nor is the `layoutGuides` array: an update replaces them whole.
    static let nestedKeys: Set<String> = ["stroke", "sizing", "text", "image", "icon", "layout", "padding", "versionSnapshot"]

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
        try unsupported("scroll", type == .frame)
        try unsupported("layoutGuides", type == .frame)
        try unsupported("text", type == .text)
        try unsupported("image", type == .image)
        try unsupported("icon", type == .icon)
        try unsupported("versionSnapshot", type == .image)

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
            try text.checkKeys(["content", "fontSize", "fontWeight", "fontFamily", "color", "align", "lineHeight", "autoResize", "sequence"])
            let family = try text.string("fontFamily", default: "")
            node.text = DesignText(content: try text.string("content", default: ""),
                                   fontSize: try text.number("fontSize", default: 16, min: 1),
                                   fontWeight: try text.integer("fontWeight", default: 400, min: 100, max: 900),
                                   fontFamily: family.isEmpty ? nil : family,
                                   color: try text.color("color", default: .black)!,
                                   align: try text.choice("align", default: .left),
                                   lineHeight: try text.optionalNumber("lineHeight", min: 0.1),
                                   autoResize: try text.choice("autoResize", default: .widthAndHeight),
                                   sequence: try text.child("sequence").map(sequence))
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
        if type == .icon {
            guard let icon = try reader.child("icon") else { throw reader.fail("icon layer is missing icon") }
            try icon.checkKeys(["name", "color"])
            // Only the name's form is checked here: whether the icon exists depends on the icon libraries on this Mac, and a file
            // naming an icon this Mac lacks still opens (the layer draws a placeholder).
            let name = try icon.string("name")
            guard IconLibrary.parse(name) != nil else {
                throw reader.fail("icon.name must be <library>/<name> with library one of \(IconLibrary.allCases.map(\.rawValue).joined(separator: ", ")); got \(name)")
            }
            node.icon = DesignIcon(name: name, color: try icon.color("color", default: .black)!)
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
        node.scroll = try reader.choice("scroll", default: .none)
        node.fixedOnScroll = try reader.bool("fixedOnScroll", default: false)
        if let states = try reader.child("states") {
            try states.checkKeys(["hover", "pressed"])
            func style(_ key: String) throws -> LayerStyle? {
                guard let style = try states.child(key) else { return nil }
                try style.checkKeys(["fill", "opacity"])
                return LayerStyle(fill: try style.color("fill"), opacity: style.value("opacity") == nil ? nil : try style.number("opacity", min: 0, max: 1))
            }
            let value = LayerStates(hover: try style("hover"), pressed: try style("pressed"))
            node.states = value == LayerStates() ? nil : value
        }
        if let animation = try reader.child("animation") {
            node.animation = try self.animation(animation)
        }
        if let snapshot = try reader.child("versionSnapshot") {
            try snapshot.checkKeys(["frame", "createdAt", "note"])
            let frame = try snapshot.string("frame")
            guard !frame.isEmpty else { throw reader.fail("\(snapshot.name("frame")) must be a non-empty frame id") }
            let text = try snapshot.string("createdAt")
            guard let date = VersionSnapshot.date(text) else {
                throw reader.fail("\(snapshot.name("createdAt")) must be an ISO 8601 date and time such as 2026-11-20T09:30:00Z; got \(text)")
            }
            node.versionSnapshot = VersionSnapshot(frame: frame, createdAt: date, note: try snapshot.string("note", default: ""))
        }
        if let guides = reader.value("layoutGuides") {
            guard let list = guides as? [[String: Any]] else { throw reader.fail("layoutGuides must be an array of objects") }
            node.layoutGuides = try list.enumerated().map { index, object in
                try layoutGuide(Reader(object: object, owner: id, path: "layoutGuides[\(index)]"))
            }
        }
        if let children = reader.value("children") {
            guard let list = children as? [Any] else { throw reader.fail("children must be an array") }
            node.children = try list.map(node(from:))
        }
        return node
    }

    static let actions = ["navigate", "back", "open-overlay", "close-overlay", "toggle-visibility"]

    static func interaction(_ reader: Reader) throws -> DesignInteraction {
        let action = try reader.string("action")
        func destination() throws -> String {
            let destination = try reader.string("destination")
            guard !destination.isEmpty else { throw reader.fail("\(reader.name("destination")) must be a non-empty frame id") }
            return destination
        }
        switch action {
        case "back":
            try reader.checkKeys(["action"])
            return .back
        case "close-overlay":
            try reader.checkKeys(["action"])
            return .closeOverlay
        case "navigate":
            try reader.checkKeys(["action", "destination", "transition"])
            return .navigate(destination: try destination(), transition: try transition(reader))
        case "open-overlay":
            try reader.checkKeys(["action", "destination", "position", "background", "closeOnOutsideClick", "transition"])
            let overlay = OverlaySettings(position: try reader.choice("position", default: .center), background: try reader.color("background"),
                                          closeOnOutsideClick: try reader.bool("closeOnOutsideClick", default: true))
            return .openOverlay(destination: try destination(), overlay: overlay, transition: try transition(reader))
        case "toggle-visibility":
            try reader.checkKeys(["action", "targets"])
            guard let list = reader.value("targets") else { throw reader.fail("missing \(reader.name("targets"))") }
            guard let targets = list as? [String], !targets.isEmpty, !targets.contains("") else {
                throw reader.fail("\(reader.name("targets")) must be a non-empty array of layer ids")
            }
            return .toggleVisibility(targets: targets)
        default:
            throw reader.fail("\(reader.name("action")) must be one of \(actions.joined(separator: ", ")); got \(action)")
        }
    }

    static func transition(_ reader: Reader) throws -> PrototypeTransition {
        guard let value = try reader.child("transition") else { return PrototypeTransition() }
        try value.checkKeys(["type", "duration", "easing"])
        return PrototypeTransition(type: try value.choice("type", default: .none),
                                   duration: try value.number("duration", default: 0.3, min: 0, max: PrototypeTransition.maximumDuration),
                                   easing: try value.choice("easing", default: .easeOut))
    }

    static func animation(_ reader: Reader) throws -> LayerAnimation {
        let type: AnimationType = try reader.choice("type", default: .fadeIn)
        guard reader.value("type") != nil else { throw reader.fail("missing \(reader.name("type"))") }
        var keys: Set<String> = ["type", "duration", "delay", "easing", "repeat"]
        if type == .slideIn { keys.formUnion(["from", "distance"]) }
        if type == .pulse { keys.insert("property") }
        try reader.checkKeys(keys)
        var animation = LayerAnimation(type: type)
        animation.from = try reader.choice("from", default: animation.from)
        animation.distance = try reader.number("distance", default: animation.distance, min: 0, max: LayerAnimation.maximumDistance)
        animation.property = try reader.choice("property", default: animation.property)
        animation.duration = try reader.number("duration", default: animation.duration, max: LayerAnimation.maximumDuration)
        guard animation.duration > 0 else { throw reader.fail("\(reader.name("duration")) must be greater than 0") }
        animation.delay = try reader.number("delay", default: 0, min: 0, max: LayerAnimation.maximumDelay)
        animation.easing = try reader.choice("easing", default: animation.easing)
        if let count = reader.value("repeat") {
            if count as? String == "infinite" {
                animation.repeatCount = nil
            } else if let number = count as? NSNumber, !isBool(number), number.doubleValue == number.doubleValue.rounded(),
                      (1...Double(LayerAnimation.maximumRepeat)).contains(number.doubleValue) {
                animation.repeatCount = number.intValue
            } else {
                throw reader.fail("\(reader.name("repeat")) must be an integer from 1 to \(LayerAnimation.maximumRepeat) or \"infinite\"")
            }
        }
        return animation
    }

    static func sequence(_ reader: Reader) throws -> TextSequence {
        try reader.checkKeys(["items", "interval", "loop"])
        guard let raw = reader.value("items") else { throw reader.fail("missing \(reader.name("items"))") }
        guard let items = raw as? [Any], let strings = items as? [String], (1...TextSequence.maximumItems).contains(strings.count) else {
            throw reader.fail("\(reader.name("items")) must hold 1 to \(TextSequence.maximumItems) strings")
        }
        return TextSequence(items: strings,
                            interval: try reader.number("interval", default: 1, min: TextSequence.minimumInterval, max: TextSequence.maximumInterval),
                            loop: try reader.bool("loop", default: false))
    }

    static func layoutGuide(_ reader: Reader) throws -> LayoutGuide {
        guard reader.value("type") != nil else { throw reader.fail("missing \(reader.name("type"))") }
        var guide = LayoutGuide(type: try reader.choice("type", default: .grid))
        if guide.type == .grid {
            try reader.checkKeys(["type", "size", "color", "visible"])
            guide.size = try reader.number("size", default: guide.size, min: 1)
        } else {
            try reader.checkKeys(["type", "count", "align", "width", "gutter", "margin", "color", "visible"])
            guide.count = try reader.integer("count", default: Double(guide.count), min: 1, max: Double(LayoutGuide.maximumCount))
            guide.align = try reader.choice("align", default: guide.align)
            if guide.align == .stretch, reader.value("width") != nil {
                throw reader.fail("\(reader.name("width")) only applies when align is start, center, or end")
            }
            guide.width = try reader.number("width", default: guide.width, min: 1)
            guide.gutter = try reader.number("gutter", default: guide.gutter, min: 0)
            guide.margin = try reader.number("margin", default: guide.margin, min: 0)
        }
        guide.color = try reader.color("color", default: guide.color)!
        guide.visible = try reader.bool("visible", default: true)
        return guide
    }

    static func layoutGuideObject(_ guide: LayoutGuide) -> [String: Any] {
        var object: [String: Any] = ["type": guide.type.rawValue, "color": guide.color.hex, "visible": guide.visible]
        if guide.type == .grid {
            object["size"] = guide.size
        } else {
            object["count"] = guide.count; object["align"] = guide.align.rawValue
            object["gutter"] = guide.gutter; object["margin"] = guide.margin
            if guide.align != .stretch { object["width"] = guide.width }
        }
        return object
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
            if let sequence = text.sequence { value["sequence"] = ["items": sequence.items, "interval": sequence.interval, "loop": sequence.loop] }
            object["text"] = value
        }
        if let image = node.image {
            object["image"] = ["data": includeImageData ? image.data.base64EncodedString() : "<\(image.data.count) bytes>",
                               "fit": image.fit.rawValue]
        }
        if let icon = node.icon { object["icon"] = ["name": icon.name, "color": icon.color.hex] }
        if let layout = node.layout {
            object["layout"] = ["direction": layout.direction.rawValue, "spacing": layout.spacing,
                                "padding": ["top": layout.padding.top, "right": layout.padding.right,
                                            "bottom": layout.padding.bottom, "left": layout.padding.left],
                                "align": layout.align.rawValue, "crossAlign": layout.crossAlign.rawValue]
        }
        func transition(_ value: PrototypeTransition) -> [String: Any] {
            ["type": value.type.rawValue, "duration": value.duration, "easing": value.easing.rawValue]
        }
        switch node.interaction {
        case .navigate(let destination, let value):
            object["interaction"] = ["action": "navigate", "destination": destination, "transition": transition(value)]
        case .back: object["interaction"] = ["action": "back"]
        case .openOverlay(let destination, let overlay, let value):
            var interaction: [String: Any] = ["action": "open-overlay", "destination": destination, "position": overlay.position.rawValue,
                                              "closeOnOutsideClick": overlay.closeOnOutsideClick, "transition": transition(value)]
            if let background = overlay.background { interaction["background"] = background.hex }
            object["interaction"] = interaction
        case .closeOverlay: object["interaction"] = ["action": "close-overlay"]
        case .toggleVisibility(let targets): object["interaction"] = ["action": "toggle-visibility", "targets": targets]
        case nil: break
        }
        if node.scroll != .none { object["scroll"] = node.scroll.rawValue }
        if node.fixedOnScroll { object["fixedOnScroll"] = true }
        if let states = node.states {
            func style(_ value: LayerStyle) -> [String: Any] {
                var style: [String: Any] = [:]
                if let fill = value.fill { style["fill"] = fill.hex }
                if let opacity = value.opacity { style["opacity"] = opacity }
                return style
            }
            var value: [String: Any] = [:]
            if let hover = states.hover { value["hover"] = style(hover) }
            if let pressed = states.pressed { value["pressed"] = style(pressed) }
            object["states"] = value
        }
        if let animation = node.animation {
            var value: [String: Any] = ["type": animation.type.rawValue, "duration": animation.duration, "delay": animation.delay,
                                        "easing": animation.easing.rawValue, "repeat": animation.repeatCount.map { $0 as Any } ?? "infinite"]
            if animation.type == .slideIn { value["from"] = animation.from.rawValue; value["distance"] = animation.distance }
            if animation.type == .pulse { value["property"] = animation.property.rawValue }
            object["animation"] = value
        }
        if let snapshot = node.versionSnapshot {
            var value: [String: Any] = ["frame": snapshot.frame, "createdAt": snapshot.timestamp]
            if !snapshot.note.isEmpty { value["note"] = snapshot.note }
            object["versionSnapshot"] = value
        }
        if !node.layoutGuides.isEmpty { object["layoutGuides"] = node.layoutGuides.map(layoutGuideObject) }
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
