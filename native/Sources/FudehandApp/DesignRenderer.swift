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
                (layer as? ImageLayer)?.rasterize(force: true)
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
        case .image: layer = ImageLayer()
        default: layer = CALayer()
        }
        // Centered, so a played animation rotates and scales a layer about its center (see `LayerAnimationPlayer`).
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
        layer.position = CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
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
            if let imageLayer = layer as? ImageLayer {
                if image.data != previous?.image?.data { imageLayer.load(image.data) } else { imageLayer.rasterize(force: false) }
            }
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

    /// Decodes SVG data with the system renderer; nil for anything else, or an SVG without a usable size.
    static func svgImage(_ data: Data) -> NSImage? {
        guard cgImage(data) == nil, DesignJSON.isSVG(data), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// The size a newly inserted image gets: half the pixel size for bitmaps (they are usually @2x), the declared size for SVG
    /// (the `viewBox` size when it declares no width and height). Nil when the data cannot be drawn.
    static func imageSize(_ data: Data) -> CGSize? {
        if let bitmap = cgImage(data) { return CGSize(width: Double(bitmap.width) / 2, height: Double(bitmap.height) / 2) }
        return svgImage(data)?.size
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
        // The bitmap has a bottom-left origin; flipping it matches the layers' top-left origin. A text or image layer's bitmap would
        // be turned upside down as a whole in this flipped context, so it is drawn reversed in advance.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        renderer.root.frame = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        renderer.root.layoutIfNeeded()
        for case let layer as TextLayer in renderer.records.values.map(\.layer) { layer.invertedForSnapshot = true; layer.displayIfNeeded() }
        for case let layer as ImageLayer in renderer.records.values.map(\.layer) { layer.invertForSnapshot() }
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

/// The layer of an image node. A bitmap is decoded once into `contents`; an SVG keeps its source and is rasterized for the size it
/// is shown at, so it stays sharp when zoomed in: again when the zoom settles (a new `contentsScale`) or the layer grows.
final class ImageLayer: CALayer {
    private var svg: NSImage?
    /// The pixel size of the current SVG raster.
    private var raster: CGSize = .zero

    @MainActor func load(_ data: Data) {
        if let bitmap = DesignRenderer.cgImage(data) {
            svg = nil
            contents = bitmap
            return
        }
        svg = DesignRenderer.svgImage(data)
        contents = nil
        rasterize(force: true)
    }

    /// Replaces the contents with a vertically mirrored copy, for the flipped snapshot context (see `snapshotPNG`).
    @MainActor func invertForSnapshot() {
        guard let value = contents, CFGetTypeID(value as CFTypeRef) == CGImage.typeID else { return }
        let image = value as! CGImage
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        contents = context.makeImage()
    }

    /// Rasterizes the SVG at the size that covers the bounds (what fill shows) × `contentsScale`. Unless forced, only when that is
    /// larger than the current raster, and then with 1.5× headroom: shrinking keeps the sharper raster, and a resize drag that
    /// enlarges the layer redraws in a few steps rather than on every frame.
    @MainActor func rasterize(force: Bool) {
        guard let svg else { return }
        let size = svg.size
        let cover = max(bounds.width / size.width, bounds.height / size.height) * contentsScale
        let limit = DesignRenderer.maximumRasterSide / max(size.width, size.height)
        let needed = CGSize(width: max(1, (size.width * min(cover, limit)).rounded(.up)), height: max(1, (size.height * min(cover, limit)).rounded(.up)))
        guard force || needed.width > raster.width || needed.height > raster.height else { return }
        let factor = min(force ? cover : cover * 1.5, limit)
        let pixels = CGSize(width: max(1, (size.width * factor).rounded(.up)), height: max(1, (size.height * factor).rounded(.up)))
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        svg.draw(in: CGRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        contents = context.makeImage()
        raster = pixels
    }
}
