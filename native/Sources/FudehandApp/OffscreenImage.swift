import AppKit
import FudehandCore
import Metal

/// One offscreen render of a node by Core Animation itself, like the canvas, so blurs, masks, and shadows come out the same
/// (`render(in:)` skips filters and masks). Snapshots and canvas bitmaps use it.
///
/// It comes in two halves (#243): `init` builds the node's layers and commits them, on the main thread, which owns the
/// layers; `draw` renders them, waits for the GPU, and reads the pixels back, on any thread. The canvas runs `draw` on a
/// background queue, so the waiting, most of the cost, does not hold up the main thread. Nothing else touches the layers
/// once `init` has committed them.
final class OffscreenImage: @unchecked Sendable {
    /// One Metal device and queue for every render.
    private static let gpu: (device: MTLDevice, queue: MTLCommandQueue)? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return (device, queue)
    }()

    /// Sets up the GPU device and Core Animation's offscreen renderer on a background queue, once, so the first bitmap or
    /// snapshot does not pay for it on the main thread (about 40 ms).
    static func warmUp() { _ = warmedUp }

    private static let warmedUp: Void = {
        DispatchQueue.global(qos: .utility).async {
            guard let (device, queue) = gpu else { return }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let stage = CALayer()
            stage.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
            stage.backgroundColor = CGColor(gray: 1, alpha: 1)
            CATransaction.commit()
            let compositor = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
            compositor.layer = stage
            compositor.bounds = stage.bounds
            CATransaction.flush()
            compositor.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            compositor.addUpdate(compositor.bounds)
            compositor.render()
            compositor.endFrame()
        }
    }()

    /// Keeps the layers alive until the render is done.
    private let renderer: DesignRenderer
    private let compositor: CARenderer
    private let texture: MTLTexture
    private let queue: MTLCommandQueue
    let width: Int
    let height: Int

    /// Builds `rect` of the node (in its own coordinates, its top-left corner at 0, 0) at `scale` pixels per point.
    @MainActor init(of node: DesignNode, in rect: CGRect, scale: Double) throws {
        renderer = DesignRenderer()
        renderer.contentsScale = scale
        var placed = node
        placed.x = -rect.minX
        placed.y = -rect.minY
        placed.visible = true
        renderer.sync([placed])
        let pixels = (width: (rect.width * scale).rounded(.up), height: (rect.height * scale).rounded(.up))
        guard pixels.width <= 16_384, pixels.height <= 16_384 else {
            throw ControlCommandError("Snapshot is too large (\(Int(pixels.width))×\(Int(pixels.height)) pixels); reduce scale")
        }
        width = max(1, Int(pixels.width))
        height = max(1, Int(pixels.height))
        // The stage has the canvas's top-left origin and scales the layers to pixels.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stage = CALayer()
        stage.isGeometryFlipped = true
        stage.frame = CGRect(x: 0, y: 0, width: width, height: height)
        renderer.root.anchorPoint = .zero
        renderer.root.frame = CGRect(origin: .zero, size: rect.size)
        renderer.root.transform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
        stage.addSublayer(renderer.root)
        CATransaction.commit()
        guard let (device, queue) = Self.gpu else { throw ControlCommandError("Could not create the snapshot canvas") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ControlCommandError("Could not create the snapshot canvas") }
        self.texture = texture
        self.queue = queue
        compositor = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace as String: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                              kCARendererMetalCommandQueue as String: queue])
        compositor.layer = stage
        compositor.bounds = stage.bounds
        // The renderer draws only what has been committed.
        CATransaction.flush()
    }

    /// Renders the layers and returns the pixels; on any thread, once.
    func draw() throws -> CGImage {
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
        return image
    }
}
