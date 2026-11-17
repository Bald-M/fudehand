import Foundation

/// 设计文档的读写与校验错误；`message` 直接展示给使用者或 Agent。
public struct DesignError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// sRGB 颜色，分量 0–1；文件中写作 `#RRGGBB` 或 `#RRGGBBAA`。
public struct DesignColor: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    public init(hex: String) throws {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : ""
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else {
            throw DesignError("颜色格式应为 #RRGGBB 或 #RRGGBBAA：\(hex)")
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
    /// 行高倍数；nil 表示字体默认行高。
    public var lineHeight: Double?
    public var autoResize: TextAutoResize

    public init(content: String, fontSize: Double = 16, fontWeight: Int = 400, fontFamily: String? = nil,
                color: DesignColor = .black, align: TextAlign = .left, lineHeight: Double? = nil,
                autoResize: TextAutoResize = .widthAndHeight) {
        self.content = content; self.fontSize = fontSize; self.fontWeight = fontWeight; self.fontFamily = fontFamily
        self.color = color; self.align = align; self.lineHeight = lineHeight; self.autoResize = autoResize
    }
}

public enum ImageFit: String, Sendable, CaseIterable { case fill, fit, stretch }

public struct DesignImage: Equatable, Sendable {
    /// PNG 或 JPEG 原始字节；文件中以 base64 保存。
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

/// 画框的自动布局。
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

public enum NodeType: String, Sendable, CaseIterable {
    case frame, rectangle, ellipse, text, image, group

    /// 新建图层的默认名称。
    public var title: String {
        switch self {
        case .frame: return "画框"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .image: return "图片"
        case .group: return "分组"
        }
    }

    public var hasChildren: Bool { self == .frame || self == .group }
    public var hasCornerRadius: Bool { self == .frame || self == .rectangle || self == .image }
}

/// 图层树中的一个节点。坐标相对父节点，`children` 的顺序即层叠顺序（后者在上）。
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

/// 一份设计文档：顶层图层的有序列表。
public struct DesignDocument: Equatable, Sendable {
    public static let format = "ui-atlas.design"
    public static let formatVersion = 1
    public static let fileExtension = "uiatlas"

    public var nodes: [DesignNode]
    public init(nodes: [DesignNode] = []) { self.nodes = nodes }

    public static func decode(_ data: Data) throws -> DesignDocument {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == format else { throw DesignError("不是 ui-atlas 工程文件") }
        guard let version = object["version"] as? NSNumber, !DesignJSON.isBool(version), version.doubleValue == version.doubleValue.rounded(),
              version.intValue >= 1 else {
            throw DesignError("工程文件缺少格式版本号")
        }
        if version.intValue > formatVersion {
            throw DesignError("文件由更新版本的 ui-atlas 创建（格式版本 \(version.intValue)），请升级后再打开")
        }
        guard let nodes = object["nodes"] as? [Any] else { throw DesignError("工程文件缺少 nodes") }
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
        if let duplicate { throw DesignError("图层 id 重复：\(duplicate)") }
    }

    /// 深度优先遍历全部节点。
    public func forEach(_ body: (DesignNode) -> Void) {
        func visit(_ nodes: [DesignNode]) { for node in nodes { body(node); visit(node.children) } }
        visit(nodes)
    }

    public var nodeCount: Int { var count = 0; forEach { _ in count += 1 }; return count }
}
