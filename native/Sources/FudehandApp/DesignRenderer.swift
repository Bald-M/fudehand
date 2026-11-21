import AppKit
import CoreImage
import FudehandCore
import ImageIO
import Metal

/// Syncs the design document to a Core Animation layer tree: one layer per node, reused by id, updating only the properties that changed.
@MainActor
final class DesignRenderer {
    /// The parent of all top-level layers. The canvas puts it inside the flipped world view layer, which already has a top-left origin, so it is not flipped again here.
    let root = CALayer()
    /// One per node, so a sync looks each id up once.
    private final class Record {
        /// What the parent holds: `content` itself, or, while the node has effects, a plain layer around it that also holds the
        /// drop shadows and background blurs. It carries the node's position, opacity, visibility, and layer blur, so a played
        /// animation moves and fades the effects with the layer.
        var layer: CALayer
        /// The layer of the node's type: fill, stroke, text, image, or icon, and the child layers.
        let content: CALayer
        /// Inner shadows and noise, drawn inside `content` below the child layers.
        var innerShadows: [CALayer] = []
        /// Background blurs, next to `layer` in the parent, just under it (see `EffectLayers.Built.backdrops`).
        var backdrops: [CALayer] = []
        /// Copies of a text or icon layer that effects draw from, kept at the same raster scale.
        var copies: [CALayer] = []
        /// The node last applied to the layer (without children), used to skip unchanged nodes.
        var applied: DesignNode?
        /// The sync that last saw the node; records an older sync left behind belong to deleted nodes.
        var pass = 0
        init(_ layer: CALayer) { self.layer = layer; content = layer }
    }
    private var records: [String: Record] = [:]
    private var pass = 0
    /// Text and images are rasterized at this scale: screen scale × canvas zoom.
    var contentsScale: CGFloat = 2 {
        didSet {
            guard contentsScale != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in records.values.flatMap({ [$0.content] + $0.copies }) where layer is TextLayer || layer is ShaderLayer || layer.contents != nil {
                layer.contentsScale = Self.rasterScale(contentsScale, for: layer.bounds.size)
                if layer is TextLayer || layer is ShaderLayer { layer.setNeedsDisplay() }
                (layer as? ImageLayer)?.rasterize(force: true)
                (layer as? IconLayer)?.rasterize(force: true)
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
    /// The layer that draws the node's fill; differs from `layer(for:)` while the node has effects.
    func contentLayer(for id: String) -> CALayer? { records[id]?.content }
    /// The node's background blur layers. They sit outside `layer(for:)`, so an animation of that layer is also added to these.
    func backdrops(for id: String) -> [CALayer] { records[id]?.backdrops ?? [] }

    /// The available fonts changed: the next sync typesets every text layer again, even when its node is unchanged.
    func fontsChanged() {
        // Forgetting only the text keeps the layer (a nil `applied` would read as a type change and replace it).
        for record in records.values where record.content is TextLayer { record.applied?.text = nil }
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
                record.backdrops.forEach { $0.removeFromSuperlayer() }
                records[id] = nil
            }
        }
        CATransaction.commit()
    }

    /// Returns the number of nodes synced, descendants included. `below` are the parent's own layers kept under its children.
    private func syncChildren(of parent: CALayer, _ nodes: [DesignNode], below: [CALayer] = []) -> Int {
        var ordered = below
        var seen = nodes.count
        for node in nodes {
            var record = records[node.id]
            if let existing = record, existing.applied?.type != node.type {
                existing.layer.removeFromSuperlayer()
                existing.backdrops.forEach { $0.removeFromSuperlayer() }
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
                Self.apply(node, to: current.content, previous: current.applied, scale: contentsScale)
                applyEffects(node, to: current)
                current.applied = shallow
            }
            seen += syncChildren(of: current.content, node.children, below: current.innerShadows)
            ordered += current.backdrops
            ordered.append(current.layer)
        }
        let current = parent.sublayers ?? []
        if current.count != ordered.count || !zip(current, ordered).allSatisfy({ $0 === $1 }) {
            parent.sublayers = ordered
        }
        return seen
    }

    /// Builds the node's effect layers again when anything they depend on changed, wraps `content` while the node has visible
    /// effects, and moves the node's placement, opacity, and visibility onto the wrapper.
    private func applyEffects(_ node: DesignNode, to record: Record) {
        let wanted = node.effects.contains(where: \.visible)
        // Without a wrapper the node has no effect layers, so a node without effects has nothing to update.
        guard wanted || record.layer !== record.content else { return }
        if wanted != (record.layer !== record.content) {
            if wanted {
                let wrapper = CALayer()
                wrapper.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                wrapper.actions = Self.noActions
                record.layer = wrapper
            } else {
                record.content.removeFromSuperlayer()
                record.layer = record.content
            }
            record.applied?.effects = []
        }
        func inputs(_ node: DesignNode) -> DesignNode {
            var node = node
            node.x = 0; node.y = 0; node.opacity = 1; node.visible = true; node.name = ""; node.children = []
            return node
        }
        if record.applied.map(inputs) != inputs(node) {
            let built = wanted ? EffectLayers.build(node, scale: contentsScale) : EffectLayers.Built()
            // A shader that only changed size keeps showing its bitmap until the size settles (see `ShaderLayer.carryOver`).
            for (old, new) in zip(record.innerShadows.compactMap { $0 as? ShaderLayer }, built.inner.compactMap { $0 as? ShaderLayer }) {
                new.carryOver(from: old)
            }
            record.innerShadows = built.inner
            // Playback animations added to the old background blurs (see `backdrops(for:)`) carry over, so a restyle mid-animation
            // (a hover fill, the next text sequence item) does not stop the blur while its layer keeps moving.
            for (old, new) in zip(record.backdrops, built.backdrops) {
                for key in old.animationKeys() ?? [] { if let animation = old.animation(forKey: key) { new.add(animation, forKey: key) } }
            }
            record.backdrops = built.backdrops
            record.copies = built.copies
            record.layer.filters = built.filters.isEmpty ? nil : built.filters
            record.layer.transform = built.transform
            for backdrop in built.backdrops { backdrop.transform = built.transform }
            record.content.sublayerTransform = built.sublayerTransform
            if wanted { record.layer.sublayers = built.behind + [record.content] }
        }
        guard wanted else { return }
        let wrapper = record.layer, content = record.content
        wrapper.position = content.position
        wrapper.bounds = content.bounds
        wrapper.isHidden = content.isHidden
        wrapper.opacity = content.opacity
        for backdrop in record.backdrops {
            backdrop.position = wrapper.position
            backdrop.isHidden = wrapper.isHidden
            backdrop.opacity = wrapper.opacity
        }
        content.position = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
        content.isHidden = false
        content.opacity = 1
    }

    static func makeLayer(for type: NodeType, scale: CGFloat) -> CALayer {
        let layer: CALayer
        switch type {
        case .ellipse: layer = CAShapeLayer()
        case .text: layer = TextLayer()
        case .image: layer = ImageLayer()
        case .icon: layer = IconLayer()
        default: layer = CALayer()
        }
        // Centered, so a played animation rotates and scales a layer about its center (see `LayerAnimationPlayer`).
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
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
        if node.type == .text || node.type == .image || node.type == .icon { layer.contentsScale = rasterScale(scale, for: layer.bounds.size) }
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
        if let icon = node.icon, let iconLayer = layer as? IconLayer { iconLayer.update(icon) }
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
        // Rendered by Core Animation itself, like the canvas, so blurs, masks, and shadows come out the same; `render(in:)` skips
        // filters and masks. The stage has the canvas's top-left origin and scales the layers to pixels.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stage = CALayer()
        stage.isGeometryFlipped = true
        stage.frame = CGRect(x: 0, y: 0, width: width, height: height)
        renderer.root.anchorPoint = .zero
        renderer.root.frame = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        renderer.root.transform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
        stage.addSublayer(renderer.root)
        CATransaction.commit()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ControlCommandError("Could not create the snapshot canvas")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ControlCommandError("Could not create the snapshot canvas") }
        let compositor = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace as String: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                 kCARendererMetalCommandQueue as String: queue])
        compositor.layer = stage
        compositor.bounds = stage.bounds
        // The renderer draws only what has been committed.
        CATransaction.flush()
        compositor.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        compositor.addUpdate(compositor.bounds)
        compositor.render()
        compositor.endFrame()
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { throw ControlCommandError("Snapshot failed") }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        // The texture's first row is the bottom of the stage.
        let rowBytes = width * 4
        var pixelData = Data(count: rowBytes * height)
        pixelData.withUnsafeMutableBytes { buffer in
            let base = buffer.baseAddress!
            for row in 0..<height {
                texture.getBytes(base + (height - 1 - row) * rowBytes, bytesPerRow: rowBytes,
                                 from: MTLRegionMake2D(0, row, width, 1), mipmapLevel: 0)
            }
        }
        guard let provider = CGDataProvider(data: pixelData as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ControlCommandError("Snapshot failed")
        }
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
