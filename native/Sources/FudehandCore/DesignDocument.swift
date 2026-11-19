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

/// How a layer looks while the pointer is over it and while it is pressed during prototype playback.
public struct LayerStates: Equatable, Sendable {
    public var hover: LayerStyle?
    public var pressed: LayerStyle?
    public init(hover: LayerStyle? = nil, pressed: LayerStyle? = nil) { self.hover = hover; self.pressed = pressed }
    /// Seconds a layer takes to change into and out of a state.
    public static let transitionDuration = 0.15
}

public enum NodeType: String, Sendable, CaseIterable {
    case frame, rectangle, ellipse, text, image, group

    /// The default name of a new layer.
    public var title: String {
        switch self {
        case .frame: return L("Frame")
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .text: return L("Text")
        case .image: return L("Image")
        case .group: return L("Group")
        }
    }

    public var hasChildren: Bool { self == .frame || self == .group }
    public var hasCornerRadius: Bool { self == .frame || self == .rectangle || self == .image }
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
    public var layout: AutoLayout?
    public var interaction: DesignInteraction?
    /// Frames only.
    public var scroll = ScrollDirection.none
    /// Stays in place, above the scrolled content, when its parent frame scrolls.
    public var fixedOnScroll = false
    public var states: LayerStates?
    public var animation: LayerAnimation?
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

/// A design document: the ordered list of top-level layers.
public struct DesignDocument: Equatable, Sendable {
    public static let format = "fudehand.design"
    /// The format name written before the product was renamed; files carrying it still open.
    static let legacyFormat = "ui-atlas.design"
    /// 2 added layer interactions, 3 layer animations and text sequences, 4 scrolling, layer states, overlays, and visibility
    /// toggles; older files open unchanged and are written as the current version.
    public static let formatVersion = 4
    public static let fileExtension = "fudehand"

    public var nodes: [DesignNode]
    public init(nodes: [DesignNode] = []) { self.nodes = nodes }

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
        let document = DesignDocument(nodes: try nodes.map { try DesignJSON.node(from: $0) })
        try document.validateUniqueIDs()
        return document
    }

    public func encoded() throws -> Data {
        let object: [String: Any] = ["format": Self.format, "version": Self.formatVersion,
                                     "nodes": nodes.map { DesignJSON.object($0, includeImageData: true) }]
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
