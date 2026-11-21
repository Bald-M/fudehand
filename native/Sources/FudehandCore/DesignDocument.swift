import Foundation

/// Errors from reading, writing, and validating a design document; `message` is shown directly to the user or the Agent.
public struct DesignError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// An sRGB color with components 0–1; written in files as `#RRGGBB` or `#RRGGBBAA`.
public struct DesignColor: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    public init(hex: String) throws {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : ""
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit), let value = UInt64(digits, radix: 16) else {
            throw DesignError("Color must be #RRGGBB or #RRGGBBAA: \(hex)")
        }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt64) -> Double { Double((rgba >> shift) & 0xFF) / 255 }
        self.init(r: channel(24), g: channel(16), b: channel(8), a: channel(0))
    }

    public var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + byte(r) + byte(g) + byte(b) + (byte(a) == "FF" ? "" : byte(a))
    }

    public static let black = DesignColor(r: 0, g: 0, b: 0)
    public static let white = DesignColor(r: 1, g: 1, b: 1)
}

public struct DesignStroke: Equatable, Sendable {
    public var color: DesignColor
    public var width: Double
    public init(color: DesignColor, width: Double) { self.color = color; self.width = width }
}

public enum TextAlign: String, Sendable, CaseIterable { case left, center, right }
public enum TextAutoResize: String, Sendable, CaseIterable { case none, height, widthAndHeight = "width-and-height" }

public struct DesignText: Hashable, Sendable {
    public var content: String
    public var fontSize: Double
    public var fontWeight: Int
    public var fontFamily: String?
    public var color: DesignColor
    public var align: TextAlign
    /// Line height multiple; nil means the font's default line height.
    public var lineHeight: Double?
    public var autoResize: TextAutoResize
    /// Contents prototype playback shows in turn instead of `content`; editing and snapshots show `content`.
    public var sequence: TextSequence?

    public init(content: String, fontSize: Double = 16, fontWeight: Int = 400, fontFamily: String? = nil,
                color: DesignColor = .black, align: TextAlign = .left, lineHeight: Double? = nil,
                autoResize: TextAutoResize = .widthAndHeight, sequence: TextSequence? = nil) {
        self.content = content; self.fontSize = fontSize; self.fontWeight = fontWeight; self.fontFamily = fontFamily
        self.color = color; self.align = align; self.lineHeight = lineHeight; self.autoResize = autoResize; self.sequence = sequence
    }
}

public enum ImageFit: String, Sendable, CaseIterable { case fill, fit, stretch }

public struct DesignImage: Equatable, Sendable {
    /// Raw PNG, JPEG, or SVG bytes; saved in files as base64. SVG keeps its source and is rasterized when drawn.
    public var data: Data
    public var fit: ImageFit
    public init(data: Data, fit: ImageFit = .fill) { self.data = data; self.fit = fit }
}

/// A built-in icon library. An icon is addressed as `<library>/<name>`, e.g. `sf/house.fill` or `material-rounded/home.fill`.
public enum IconLibrary: String, Sendable, CaseIterable {
    case sf, materialOutlined = "material-outlined", materialRounded = "material-rounded", materialSharp = "material-sharp", weui, lucide

    /// Splits `<library>/<name>`; nil when the library is unknown or either part is empty.
    public static func parse(_ fullName: String) -> (library: IconLibrary, name: String)? {
        guard let slash = fullName.firstIndex(of: "/"), let library = IconLibrary(rawValue: String(fullName[..<slash])) else { return nil }
        let name = String(fullName[fullName.index(after: slash)...])
        return name.isEmpty ? nil : (library, name)
    }
}

/// An icon layer's content: only the icon's name and color are stored; its artwork comes from the icon library when drawn.
public struct DesignIcon: Equatable, Sendable {
    public var name: String
    public var color: DesignColor
    public init(name: String, color: DesignColor = .black) { self.name = name; self.color = color }
}

public struct EdgeInsets: Equatable, Sendable {
    public var top: Double, right: Double, bottom: Double, left: Double
    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }
}

public enum LayoutDirection: String, Sendable, CaseIterable { case horizontal, vertical }
public enum LayoutAlign: String, Sendable, CaseIterable { case start, center, end, spaceBetween = "space-between" }
public enum LayoutCrossAlign: String, Sendable, CaseIterable { case start, center, end, stretch }

/// A frame's auto layout.
public struct AutoLayout: Equatable, Sendable {
    public var direction: LayoutDirection
    public var spacing: Double
    public var padding: EdgeInsets
    public var align: LayoutAlign
    public var crossAlign: LayoutCrossAlign
    public init(direction: LayoutDirection = .vertical, spacing: Double = 0, padding: EdgeInsets = EdgeInsets(),
                align: LayoutAlign = .start, crossAlign: LayoutCrossAlign = .start) {
        self.direction = direction; self.spacing = spacing; self.padding = padding; self.align = align; self.crossAlign = crossAlign
    }
}

public enum SizingMode: String, Sendable, CaseIterable { case fixed, hug, fill }

public struct Sizing: Equatable, Sendable {
    public var horizontal: SizingMode
    public var vertical: SizingMode
    public init(horizontal: SizingMode = .fixed, vertical: SizingMode = .fixed) { self.horizontal = horizontal; self.vertical = vertical }
    public static let fixed = Sizing()
}

/// How a prototype transition moves between frames. A push names the direction the content travels: `push-left` brings the
/// destination in from the right edge. `sheet` slides the destination up from the bottom over the current frame.
public enum TransitionType: String, Sendable, CaseIterable {
    case none, dissolve, pushLeft = "push-left", pushRight = "push-right", pushUp = "push-up", pushDown = "push-down", sheet
}

public enum TransitionEasing: String, Sendable, CaseIterable { case linear, easeIn = "ease-in", easeOut = "ease-out", easeInOut = "ease-in-out" }

public struct PrototypeTransition: Equatable, Sendable {
    public var type: TransitionType
    /// Seconds.
    public var duration: Double
    public var easing: TransitionEasing
    public init(type: TransitionType = .none, duration: Double = 0.3, easing: TransitionEasing = .easeOut) {
        self.type = type; self.duration = duration; self.easing = easing
    }
    public static let maximumDuration = 10.0
}

/// Where an overlay is placed over the frame on show: centered, along the bottom edge, or just below the layer that opened it.
public enum OverlayPosition: String, Sendable, CaseIterable { case center, bottom, belowTrigger = "below-trigger" }

/// How an overlay opens: where it sits, the color drawn between it and the frame below (nil draws none), and whether a click
/// outside it closes it.
public struct OverlaySettings: Equatable, Sendable {
    public var position: OverlayPosition
    public var background: DesignColor?
    public var closeOnOutsideClick: Bool
    public init(position: OverlayPosition = .center, background: DesignColor? = nil, closeOnOutsideClick: Bool = true) {
        self.position = position; self.background = background; self.closeOnOutsideClick = closeOnOutsideClick
    }
}

/// A layer's click interaction in a prototype: go to a top-level frame, or back to the frame shown before it; open a top-level
/// frame as an overlay over the frame on show, or close the topmost overlay; or show the hidden and hide the shown among some layers.
/// Going back replays, in reverse, the transition that arrived at the current frame.
public enum DesignInteraction: Equatable, Sendable {
    case navigate(destination: String, transition: PrototypeTransition)
    case back
    case openOverlay(destination: String, overlay: OverlaySettings, transition: PrototypeTransition)
    case closeOverlay
    case toggleVisibility(targets: [String])
}

/// The direction a frame's content scrolls in prototype playback when it overflows the frame.
public enum ScrollDirection: String, Sendable, CaseIterable { case none, vertical, horizontal }

/// The look a layer takes on in one state during prototype playback; nil fields keep the layer's own value.
public struct LayerStyle: Equatable, Sendable {
    public var fill: DesignColor?
    public var opacity: Double?
    public init(fill: DesignColor? = nil, opacity: Double? = nil) { self.fill = fill; self.opacity = opacity }
}

public enum EffectType: String, Sendable, CaseIterable {
    case dropShadow = "drop-shadow", innerShadow = "inner-shadow", layerBlur = "layer-blur", backgroundBlur = "background-blur", noise, texture, glass,
         transform3D = "transform-3d", perspective
    public var isShadow: Bool { self == .dropShadow || self == .innerShadow }
    /// Marked Beta in the add menu: these turn layers only on screen; layout, selection, and hit testing still use their flat
    /// rectangles (ADR 0012).
    public var isBeta: Bool { self == .transform3D || self == .perspective }

    /// Whether a layer of `type` takes this effect. Noise, texture, and glass paint over a layer's area, so only frames,
    /// rectangles, and ellipses do.
    /// Perspective is how a frame's children are seen, so only frames take it.
    public func supports(_ type: NodeType) -> Bool {
        switch self {
        case .noise, .texture, .glass: return type == .frame || type == .rectangle || type == .ellipse
        case .perspective: return type == .frame
        default: return type.hasEffects
        }
    }
}

/// How a texture combines with what is under it in its layer.
public enum TextureBlend: String, Sendable, CaseIterable {
    case normal, multiply, screen, overlay, softLight = "soft-light"
}

/// One entry in a layer's effects list. A shadow uses color, offset, radius, and spread; a blur uses only `radius`; noise uses
/// color, size, density, and seed (see `NoiseTile`); a texture uses its image, size (the tile width), opacity, and blend;
/// glass uses radius (its backdrop blur), saturation, color (the tint drawn over the backdrop), and highlight; a 3D transform
/// uses rotateX, rotateY, and translateZ; perspective uses distance, originX, and originY.
/// Shadows of frames, rectangles,
/// ellipses, and images follow the layer's shape (spread grows or shrinks it); those of text and icons follow the glyphs and
/// ignore spread. A drop shadow is not drawn under the layer itself, so it does not show through a see-through fill.
public struct DesignEffect: Equatable, Sendable {
    public var type: EffectType
    public var visible: Bool
    public var color: DesignColor
    public var x: Double
    public var y: Double
    /// The blur radius in points; a Gaussian blur with a standard deviation of half of it.
    public var radius: Double
    public var spread: Double
    /// Noise: the side of a grain in points. Texture: the width of one tile in points; its height follows the image.
    public var size: Double
    /// Noise only: the share of grain cells drawn, 0–1.
    public var density: Double
    /// Noise only: picks the grain pattern; the same seed gives the same grains everywhere.
    public var seed: Int
    /// Texture only: the PNG, JPEG, or SVG that is tiled; saved in files as base64.
    public var texture: Data?
    /// Texture only: 0–1.
    public var opacity: Double
    /// Texture only.
    public var blend: TextureBlend
    /// Glass only: how much the blurred backdrop's colors are boosted, 0–2 (1 leaves them).
    public var saturation: Double
    /// Glass only: the opacity, 0–1, of a light edge along the inside of the shape's top.
    public var highlight: Double
    /// 3D transform only: degrees about the layer's horizontal and vertical center lines, and points toward the viewer.
    public var rotateX: Double
    public var rotateY: Double
    public var translateZ: Double
    /// Perspective only: how far in front of the frame its children are seen from, in points, and from where, as fractions of
    /// the frame's width and height.
    public var distance: Double
    public var originX: Double
    public var originY: Double

    /// `color` defaults to black at 25% opacity for a shadow, black at 20% for noise, and white at 20% for glass; `size` to 1
    /// for noise and 64 for a texture; `radius` to 4, or 20 for glass.
    public init(type: EffectType, visible: Bool = true, color: DesignColor? = nil, x: Double = 0, y: Double = 4,
                radius: Double? = nil, spread: Double = 0, size: Double? = nil, density: Double = 0.5, seed: Int = 0,
                texture: Data? = nil, opacity: Double = 1, blend: TextureBlend = .normal, saturation: Double = 1.4, highlight: Double = 0.5,
                rotateX: Double = 0, rotateY: Double = 0, translateZ: Double = 0, distance: Double = 800, originX: Double = 0.5,
                originY: Double = 0.5) {
        self.type = type; self.visible = visible; self.x = x; self.y = y; self.radius = radius ?? (type == .glass ? 20 : 4); self.spread = spread
        self.color = color ?? (type == .glass ? DesignColor(r: 1, g: 1, b: 1, a: 51.0 / 255)
                               : DesignColor(r: 0, g: 0, b: 0, a: type == .noise ? 51.0 / 255 : 64.0 / 255))
        self.size = size ?? (type == .texture ? 64 : 1); self.density = density; self.seed = seed
        self.texture = texture; self.opacity = opacity; self.blend = blend; self.saturation = saturation; self.highlight = highlight
        self.rotateX = rotateX; self.rotateY = rotateY; self.translateZ = translateZ
        self.distance = distance; self.originX = originX; self.originY = originY
    }

    public static let maximumRadius = 250.0
    public static let noiseSizes = 0.5...8.0
    public static let textureSizes = 4.0...1024.0
    /// Past 80° a layer turns edge-on and vanishes.
    public static let maximumRotation = 80.0
    public static let maximumDepth = 1000.0
    public static let perspectiveDistances = 100.0...10_000.0
}

/// How a layer looks while the pointer is over it and while it is pressed during prototype playback.
public struct LayerStates: Equatable, Sendable {
    public var hover: LayerStyle?
    public var pressed: LayerStyle?
    public init(hover: LayerStyle? = nil, pressed: LayerStyle? = nil) { self.hover = hover; self.pressed = pressed }
    /// Seconds a layer takes to change into and out of a state.
    public static let transitionDuration = 0.15
}

public enum NodeType: String, Sendable, CaseIterable {
    case frame, rectangle, ellipse, text, image, icon, group

    /// The default name of a new layer.
    public var title: String {
        switch self {
        case .frame: return L("Frame")
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .text: return L("Text")
        case .image: return L("Image")
        case .icon: return L("Icon")
        case .group: return L("Group")
        }
    }

    public var hasChildren: Bool { self == .frame || self == .group }
    public var hasCornerRadius: Bool { self == .frame || self == .rectangle || self == .image }
    public var hasEffects: Bool { self != .group }
}

/// One node in the layer tree. Coordinates are relative to the parent node, and the order of `children` is the stacking order (later ones on top).
public struct DesignNode: Equatable, Sendable, Identifiable {
    public var id: String
    public var type: NodeType
    public var name: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var visible = true
    public var locked = false
    public var opacity = 1.0
    public var fill: DesignColor?
    public var stroke: DesignStroke?
    public var cornerRadius = 0.0
    public var clipsContent = true
    public var sizing = Sizing.fixed
    public var text: DesignText?
    public var image: DesignImage?
    public var icon: DesignIcon?
    public var layout: AutoLayout?
    public var interaction: DesignInteraction?
    /// Frames only.
    public var scroll = ScrollDirection.none
    /// Stays in place, above the scrolled content, when its parent frame scrolls.
    public var fixedOnScroll = false
    public var states: LayerStates?
    public var animation: LayerAnimation?
    /// Image layers only: set when the layer is a version snapshot of a frame.
    public var versionSnapshot: VersionSnapshot?
    /// Drawn in order: later effects on top.
    public var effects: [DesignEffect] = []
    /// Frames only: grids, columns, and rows drawn over the frame on the editing canvas, in the order they were added.
    public var layoutGuides: [LayoutGuide] = []
    public var children: [DesignNode] = []

    public init(id: String, type: NodeType, name: String? = nil, x: Double = 0, y: Double = 0,
                width: Double = 100, height: Double = 100) {
        self.id = id; self.type = type; self.name = name ?? type.title
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var frame: Rect {
        get { Rect(x: x, y: y, width: width, height: height) }
        set { x = newValue.x; y = newValue.y; width = newValue.width; height = newValue.height }
    }
}

/// A design document: the ordered list of top-level layers and the annotations pinned to them.
public struct DesignDocument: Equatable, Sendable {
    public static let format = "fudehand.design"
    /// The format name written before the product was renamed; files carrying it still open.
    static let legacyFormat = "ui-atlas.design"
    /// 2 added layer interactions, 3 layer animations and text sequences, 4 scrolling, layer states, overlays, and visibility
    /// toggles, 5 icon layers, 6 version snapshots, 7 annotations, 8 frame layout guides, 9 effects; older files open unchanged and are
    /// written as the current version.
    public static let formatVersion = 9
    public static let fileExtension = "fudehand"

    public var nodes: [DesignNode]
    /// Notes pinned to layers, in the order they were added (ADR 0011).
    public var annotations: [DesignAnnotation]
    public init(nodes: [DesignNode] = [], annotations: [DesignAnnotation] = []) { self.nodes = nodes; self.annotations = annotations }

    public static func decode(_ data: Data) throws -> DesignDocument {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              [format, legacyFormat].contains(object["format"] as? String) else { throw DesignError(L("Not a Fudehand project file")) }
        guard let version = object["version"] as? NSNumber, !DesignJSON.isBool(version), version.doubleValue == version.doubleValue.rounded(),
              version.intValue >= 1 else {
            throw DesignError(L("Project file is missing its format version"))
        }
        if version.intValue > formatVersion {
            throw DesignError(L("File was created by a newer version of Fudehand (format version %d); upgrade Fudehand to open it", version.intValue))
        }
        guard let nodes = object["nodes"] as? [Any] else { throw DesignError(L("Project file is missing nodes")) }
        let annotations: [Any]
        switch object["annotations"] {
        case nil, is NSNull: annotations = []
        case let list as [Any]: annotations = list
        default: throw DesignError("annotations must be an array")
        }
        let document = DesignDocument(nodes: try nodes.map { try DesignJSON.node(from: $0) },
                                      annotations: try annotations.map(DesignAnnotation.from))
        try document.validateUniqueIDs()
        try document.validateAnnotations()
        return document
    }

    public func encoded() throws -> Data {
        var object: [String: Any] = ["format": Self.format, "version": Self.formatVersion,
                                     "nodes": nodes.map { DesignJSON.object($0, includeImageData: true) }]
        if !annotations.isEmpty { object["annotations"] = annotations.map(\.object) }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(UInt8(ascii: "\n"))
        return data
    }

    func validateUniqueIDs() throws {
        var seen = Set<String>()
        var duplicate: String?
        forEach { node in if !seen.insert(node.id).inserted, duplicate == nil { duplicate = node.id } }
        if let duplicate { throw DesignError("Duplicate layer id: \(duplicate)") }
    }

    /// Depth-first traversal of all nodes.
    public func forEach(_ body: (DesignNode) -> Void) {
        func visit(_ nodes: [DesignNode]) { for node in nodes { body(node); visit(node.children) } }
        visit(nodes)
    }

    public var nodeCount: Int { var count = 0; forEach { _ in count += 1 }; return count }
}
