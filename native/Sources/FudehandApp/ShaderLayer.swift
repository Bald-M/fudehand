import AppKit
import FudehandCore
import Metal

/// Draws a shader effect: the `ShaderCatalog` entry's Metal function, run once per change over the layer's pixels (its size ×
/// raster scale, within `maximumPixels`), shown as the layer's contents. Shaders are static, so nothing redraws per frame; a
/// new zoom (`contentsScale`) or size draws again. The layer carries the effect's opacity and blend.
final class ShaderLayer: CALayer {
    /// The longest side of a rendered bitmap in pixels.
    static let maximumPixels: CGFloat = 4096

    var effect = DesignEffect(type: .shader) { didSet { if effect != oldValue { setNeedsDisplay() } } }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        effect = (layer as? ShaderLayer)?.effect ?? DesignEffect(type: .shader)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func display() {
        let scale = min(contentsScale, Self.maximumPixels / max(bounds.width, bounds.height, 1))
        let pixels = (width: Int((bounds.width * scale).rounded(.up)), height: Int((bounds.height * scale).rounded(.up)))
        contents = Self.image(effect, size: bounds.size, pixels: pixels)
    }

    /// Layers display on the main thread, the only user of these caches.
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    /// The effect's shader rendered at `pixels`, for a layer of `size` points; nil when there is nothing to draw or no GPU.
    static func image(_ effect: DesignEffect, size: CGSize, pixels: (width: Int, height: Int)) -> CGImage? {
        guard pixels.width > 0, pixels.height > 0, let entry = ShaderCatalog.entry(effect.shader) else { return nil }
        // The bitmap depends on the entry, its parameters, the size in points, and the pixel count.
        var values: [Float] = [Float(size.width), Float(size.height), Float(CGFloat(pixels.width) / max(size.width, 1))]
        for parameter in entry.parameters {
            switch effect.shaderParams[parameter.name] ?? parameter.defaultValue {
            case .number(let number): values.append(Float(number))
            case .color(let color): values += [Float(color.r), Float(color.g), Float(color.b), Float(color.a)]
            }
        }
        let key = "\(entry.id) \(values) \(pixels.width)×\(pixels.height)"
        if let cached = cache[key] { return cached }
        guard let image = render(function: entry.id.replacingOccurrences(of: "-", with: "_"), values: values, pixels: pixels) else { return nil }
        if cache.count >= 8 { cache.removeAll() }
        cache[key] = image
        return image
    }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    /// Compiled on first use from `source`: the Command Line Tools have no offline Metal compiler, and the source is Fudehand's own.
    private static let library: MTLLibrary? = try? device?.makeLibrary(source: source, options: nil)
    nonisolated(unsafe) private static var pipelines: [String: MTLComputePipelineState] = [:]

    private static func render(function name: String, values: [Float], pixels: (width: Int, height: Int)) -> CGImage? {
        guard let device, let queue, let library else { return nil }
        let pipeline: MTLComputePipelineState
        if let cached = pipelines[name] {
            pipeline = cached
        } else {
            guard let function = library.makeFunction(name: name), let made = try? device.makeComputePipelineState(function: function) else { return nil }
            pipelines[name] = made
            pipeline = made
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: pixels.width, height: pixels.height, mipmapped: false)
        descriptor.usage = [.shaderWrite]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(bytes: values, length: values.count * MemoryLayout<Float>.stride),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (pixels.width + 15) / 16, height: (pixels.height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: group)
        encoder.endEncoding()
        guard let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        texture.getBytes(&bytes, bytesPerRow: pixels.width * 4, from: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // The kernels write premultiplied sRGB values, the first row at the top.
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// One kernel per catalog entry, named after its id. `p` holds the layer's width and height in points, its pixels per point,
    /// then the entry's parameters in catalog order (a number takes one value, a color four: r, g, b, a). Positions are in
    /// points from the layer's top-left corner, so the pattern keeps its look at any zoom.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    static float4 color(constant float *p, int i) { return float4(p[i], p[i + 1], p[i + 2], p[i + 3]); }
    static float4 premultiplied(float4 c) { return float4(c.rgb * c.a, c.a); }
    static float2 point(uint2 gid, constant float *p) { return (float2(gid) + 0.5) / p[2]; }

    kernel void waves(texture2d<float, access::write> out [[texture(0)]], constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 at = point(gid, p);
        float scale = p[3], angle = p[4] * M_PI_F / 180;
        float2 along = float2(cos(angle), sin(angle));
        float a = dot(at, along), b = dot(at, float2(-along.y, along.x));
        float t = 0.5 + 0.5 * sin(2 * M_PI_F * a / scale + 1.5 * sin(2 * M_PI_F * b / (scale * 2.3)));
        out.write(premultiplied(mix(color(p, 5), color(p, 9), t)), gid);
    }

    kernel void mesh_gradient(texture2d<float, access::write> out [[texture(0)]], constant float *p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 uv = smoothstep(0.0, 1.0, clamp(point(gid, p) / float2(p[0], p[1]), 0.0, 1.0));
        float4 top = mix(color(p, 3), color(p, 7), uv.x), bottom = mix(color(p, 11), color(p, 15), uv.x);
        out.write(premultiplied(mix(top, bottom, uv.y)), gid);
    }

    kernel void halftone(texture2d<float, access::write> out [[texture(0)]], constant float *p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float2 at = point(gid, p);
        float size = p[3], angle = p[4] * M_PI_F / 180;
        float2 turned = float2(cos(angle) * at.x + sin(angle) * at.y, -sin(angle) * at.x + cos(angle) * at.y);
        float2 cell = (fract(turned / size) - 0.5) * size;
        // Dots grow from nothing at the left edge to touching their neighbours at the right.
        float radius = clamp(at.x / p[0], 0.0, 1.0) * size * 0.7071;
        float coverage = clamp((radius - length(cell)) * p[2] + 0.5, 0.0, 1.0);
        float4 ink = color(p, 5);
        out.write(premultiplied(float4(ink.rgb, ink.a * coverage)), gid);
    }
    """
}
