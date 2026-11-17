import AppKit
import AtlasCore
import ImageIO

/// 把设计文档同步到 Core Animation 图层树：每个节点一个图层，按 id 复用，只更新变化的属性。
@MainActor
final class DesignRenderer {
    /// 所有顶层图层的父层，几何翻转为左上角原点。
    let root = CALayer()
    private var layers: [String: CALayer] = [:]
    /// 每个图层上次应用的节点（不含子节点），用于跳过未变化的节点。
    private var applied: [String: DesignNode] = [:]
    /// 文字与图片按此比例光栅化：屏幕倍率 × 画布缩放。
    var contentsScale: CGFloat = 2 {
        didSet {
            guard contentsScale != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in layers.values where layer is TextLayer || layer.contents != nil {
                layer.contentsScale = contentsScale
                if layer is TextLayer { layer.setNeedsDisplay() }
            }
            CATransaction.commit()
        }
    }

    init() {
        root.isGeometryFlipped = true
        root.actions = Self.noActions
    }

    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "sublayers": NSNull(), "contents": NSNull(),
        "backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(), "cornerRadius": NSNull(),
        "opacity": NSNull(), "hidden": NSNull(), "path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
        "lineWidth": NSNull(), "contentsScale": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    var layerCount: Int { layers.count }
    func layer(for id: String) -> CALayer? { layers[id] }

    func sync(_ nodes: [DesignNode]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        syncChildren(of: root, nodes, seen: &seen)
        for id in layers.keys where !seen.contains(id) {
            layers[id]?.removeFromSuperlayer()
            layers[id] = nil
            applied[id] = nil
        }
        CATransaction.commit()
    }

    private func syncChildren(of parent: CALayer, _ nodes: [DesignNode], seen: inout Set<String>) {
        var ordered: [CALayer] = []
        for node in nodes {
            seen.insert(node.id)
            var layer = layers[node.id]
            if let existing = layer, applied[node.id]?.type != node.type {
                existing.removeFromSuperlayer()
                layer = nil
            }
            let target = layer ?? Self.makeLayer(for: node.type, scale: contentsScale)
            layers[node.id] = target
            var shallow = node
            shallow.children = []
            if applied[node.id] != shallow {
                Self.apply(node, to: target, previous: applied[node.id])
                applied[node.id] = shallow
            }
            syncChildren(of: target, node.children, seen: &seen)
            ordered.append(target)
        }
        let current = parent.sublayers ?? []
        if current.count != ordered.count || !zip(current, ordered).allSatisfy({ $0 === $1 }) {
            parent.sublayers = ordered
        }
    }

    static func makeLayer(for type: NodeType, scale: CGFloat) -> CALayer {
        let layer: CALayer
        switch type {
        case .ellipse: layer = CAShapeLayer()
        case .text: layer = TextLayer()
        default: layer = CALayer()
        }
        layer.anchorPoint = .zero
        layer.actions = noActions
        layer.contentsScale = scale
        return layer
    }

    static func cgColor(_ color: DesignColor?) -> CGColor? {
        color.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) }
    }

    static func apply(_ node: DesignNode, to layer: CALayer, previous: DesignNode?) {
        layer.position = CGPoint(x: node.x, y: node.y)
        layer.bounds = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        layer.isHidden = !node.visible
        layer.opacity = Float(node.opacity)
        let stroke = node.stroke.flatMap { $0.width > 0 ? $0 : nil }
        if let shape = layer as? CAShapeLayer {
            // 描边画在内侧，与矩形一致。
            let inset = (stroke?.width ?? 0) / 2
            let rect = CGRect(x: 0, y: 0, width: node.width, height: node.height).insetBy(dx: inset, dy: inset)
            shape.path = CGPath(ellipseIn: rect.width > 0 && rect.height > 0 ? rect : .zero, transform: nil)
            shape.fillColor = cgColor(node.fill)
            shape.strokeColor = cgColor(stroke?.color)
            shape.lineWidth = stroke?.width ?? 0
            return
        }
        layer.backgroundColor = cgColor(node.fill)
        layer.borderColor = cgColor(stroke?.color)
        layer.borderWidth = stroke?.width ?? 0
        layer.cornerRadius = node.type.hasCornerRadius ? min(node.cornerRadius, min(node.width, node.height) / 2) : 0
        layer.masksToBounds = node.type == .image || (node.type == .frame && node.clipsContent)
        if let textLayer = layer as? TextLayer, let text = node.text, text != previous?.text || node.width != previous?.width {
            textLayer.attributed = TextMetrics.attributed(text)
        }
        if let image = node.image {
            if image.data != previous?.image?.data { layer.contents = cgImage(image.data) }
            switch image.fit {
            case .fill: layer.contentsGravity = .resizeAspectFill
            case .fit: layer.contentsGravity = .resizeAspect
            case .stretch: layer.contentsGravity = .resize
            }
        }
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 离屏渲染一个节点（含子节点），返回 PNG；节点自身位于图片左上角。
    static func snapshotPNG(_ node: DesignNode, scale: Double) throws -> Data {
        let renderer = DesignRenderer()
        renderer.contentsScale = scale
        var placed = node
        placed.x = 0
        placed.y = 0
        placed.visible = true
        renderer.sync([placed])
        let width = max(1, Int((node.width * scale).rounded(.up)))
        let height = max(1, Int((node.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ControlCommandError("无法创建截图画布")
        }
        // 位图以左下角为原点，翻转后与图层的左上角原点一致。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        renderer.root.isGeometryFlipped = false
        renderer.root.frame = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        renderer.root.layoutIfNeeded()
        for layer in renderer.layers.values where layer is TextLayer { layer.displayIfNeeded() }
        renderer.root.render(in: context)
        guard let image = context.makeImage() else { throw ControlCommandError("截图失败") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ControlCommandError("截图编码失败")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ControlCommandError("截图编码失败") }
        return data as Data
    }
}
