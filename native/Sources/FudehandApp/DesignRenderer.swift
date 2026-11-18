import AppKit
import FudehandCore
import ImageIO

/// Syncs the design document to a Core Animation layer tree: one layer per node, reused by id, updating only the properties that changed.
@MainActor
final class DesignRenderer {
    /// The parent of all top-level layers. The canvas puts it inside the flipped world view layer, which already has a top-left origin, so it is not flipped again here.
    let root = CALayer()
    /// One per node, so a sync looks each id up once.
    private final class Record {
        let layer: CALayer
        /// The node last applied to the layer (without children), used to skip unchanged nodes.
        var applied: DesignNode?
        /// The sync that last saw the node; records an older sync left behind belong to deleted nodes.
        var pass = 0
        init(_ layer: CALayer) { self.layer = layer }
    }
    private var records: [String: Record] = [:]
    private var pass = 0
    /// Text and images are rasterized at this scale: screen scale × canvas zoom.
    var contentsScale: CGFloat = 2 {
        didSet {
            guard contentsScale != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in records.values.map(\.layer) where layer is TextLayer || layer.contents != nil {
                layer.contentsScale = Self.rasterScale(contentsScale, for: layer.bounds.size)
                if layer is TextLayer { layer.setNeedsDisplay() }
            }
            CATransaction.commit()
        }
    }

    init() {
        root.actions = Self.noActions
    }

    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "sublayers": NSNull(), "contents": NSNull(),
        "backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(), "cornerRadius": NSNull(),
        "opacity": NSNull(), "hidden": NSNull(), "path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
        "lineWidth": NSNull(), "contentsScale": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    var layerCount: Int { records.count }
    func layer(for id: String) -> CALayer? { records[id]?.layer }

    /// The available fonts changed: the next sync typesets every text layer again, even when its node is unchanged.
    func fontsChanged() {
        // Forgetting only the text keeps the layer (a nil `applied` would read as a type change and replace it).
        for record in records.values where record.layer is TextLayer { record.applied?.text = nil }
    }

    func sync(_ nodes: [DesignNode]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pass += 1
        let seen = syncChildren(of: root, nodes)
        // Ids are unique, so when as many nodes were synced as there are records, none was left behind by a deleted node.
        if seen != records.count {
            for (id, record) in records where record.pass != pass {
                record.layer.removeFromSuperlayer()
                records[id] = nil
            }
        }
        CATransaction.commit()
    }

    /// Returns the number of nodes synced, descendants included.
    private func syncChildren(of parent: CALayer, _ nodes: [DesignNode]) -> Int {
        var ordered: [CALayer] = []
        var seen = nodes.count
        for node in nodes {
            var record = records[node.id]
            if let existing = record, existing.applied?.type != node.type {
                existing.layer.removeFromSuperlayer()
                record = nil
            }
            let current = record ?? {
                let created = Record(Self.makeLayer(for: node.type, scale: contentsScale))
                records[node.id] = created
                return created
            }()
            current.pass = pass
            var shallow = node
            shallow.children = []
            if current.applied != shallow {
                Self.apply(node, to: current.layer, previous: current.applied, scale: contentsScale)
                current.applied = shallow
            }
            seen += syncChildren(of: current.layer, node.children)
            ordered.append(current.layer)
        }
        let current = parent.sublayers ?? []
        if current.count != ordered.count || !zip(current, ordered).allSatisfy({ $0 === $1 }) {
            parent.sublayers = ordered
        }
        return seen
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

    /// Upper limit on a bitmap's side length: when zoomed in many times, large text or images are not rasterized at the full scale, avoiding huge bitmaps.
    static let maximumRasterSide: CGFloat = 8192

    static func rasterScale(_ scale: CGFloat, for size: CGSize) -> CGFloat {
        let side = max(size.width, size.height, 1)
        return max(1, min(scale, maximumRasterSide / side))
    }

    static func apply(_ node: DesignNode, to layer: CALayer, previous: DesignNode?, scale: CGFloat) {
        layer.position = CGPoint(x: node.x, y: node.y)
        layer.bounds = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        if node.type == .text || node.type == .image { layer.contentsScale = rasterScale(scale, for: layer.bounds.size) }
        layer.isHidden = !node.visible
        layer.opacity = Float(node.opacity)
        let stroke = node.stroke.flatMap { $0.width > 0 ? $0 : nil }
        if let shape = layer as? CAShapeLayer {
            // The stroke is drawn on the inside, matching rectangles.
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

    /// Renders a node (with its children) offscreen and returns a PNG; the node itself sits at the top-left corner of the image.
    static func snapshotPNG(_ node: DesignNode, scale: Double) throws -> Data {
        let renderer = DesignRenderer()
        renderer.contentsScale = scale
        var placed = node
        placed.x = 0
        placed.y = 0
        placed.visible = true
        renderer.sync([placed])
        let pixels = (width: (node.width * scale).rounded(.up), height: (node.height * scale).rounded(.up))
        guard pixels.width <= 16_384, pixels.height <= 16_384 else {
            throw ControlCommandError("Snapshot is too large (\(Int(pixels.width))×\(Int(pixels.height)) pixels); reduce scale")
        }
        let width = max(1, Int(pixels.width)), height = max(1, Int(pixels.height))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ControlCommandError("Could not create the snapshot canvas")
        }
        // The bitmap has a bottom-left origin; flipping it matches the layers' top-left origin. A text layer's bitmap would be
        // turned upside down as a whole in this flipped context, so it is drawn reversed in advance.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        renderer.root.frame = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        renderer.root.layoutIfNeeded()
        for case let layer as TextLayer in renderer.records.values.map(\.layer) { layer.invertedForSnapshot = true; layer.displayIfNeeded() }
        renderer.root.render(in: context)
        guard let image = context.makeImage() else { throw ControlCommandError("Snapshot failed") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ControlCommandError("Could not encode the snapshot")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ControlCommandError("Could not encode the snapshot") }
        return data as Data
    }
}
