import AppKit
import FudehandCore

/// Draws a noise effect: `NoiseTile` repeated across the layer from its top-left corner, one tile cell per grain of the effect's
/// size in points, so grains grow with the zoom and stay put when the layer moves. Each repeat is a sublayer showing the same
/// cached tile image, scaled without smoothing, so zooming never redraws it and a large layer costs no more than one small image.
enum NoiseLayer {
    static func make(_ effect: DesignEffect, bounds: CGRect) -> CALayer {
        let holder = CALayer()
        holder.actions = DesignRenderer.noActions
        holder.frame = bounds
        guard let tile = tile(effect) else { return holder }
        let side = CGFloat(NoiseTile.side) * effect.size
        var top: CGFloat = 0
        while top < bounds.height {
            var left: CGFloat = 0
            while left < bounds.width {
                let repeated = CALayer()
                repeated.actions = DesignRenderer.noActions
                repeated.frame = CGRect(x: left, y: top, width: side, height: side)
                repeated.contents = tile
                repeated.magnificationFilter = .nearest
                repeated.minificationFilter = .nearest
                holder.addSublayer(repeated)
                left += side
            }
            top += side
        }
        return holder
    }

    private struct Key: Hashable { let color: String, density: Double, seed: Int }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tiles: [Key: CGImage] = [:]

    /// The tile in the effect's color, one pixel per cell, the top row first; made once per color, density, and seed.
    static func tile(_ effect: DesignEffect) -> CGImage? {
        let key = Key(color: effect.color.hex, density: effect.density, seed: effect.seed)
        lock.lock()
        defer { lock.unlock() }
        if let cached = tiles[key] { return cached }
        let side = NoiseTile.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for (index, strength) in NoiseTile.cells(density: effect.density, seed: effect.seed).enumerated() where strength > 0 {
            // Premultiplied alpha.
            let alpha = effect.color.a * Double(strength) / 255
            pixels[index * 4] = UInt8((effect.color.r * alpha * 255).rounded())
            pixels[index * 4 + 1] = UInt8((effect.color.g * alpha * 255).rounded())
            pixels[index * 4 + 2] = UInt8((effect.color.b * alpha * 255).rounded())
            pixels[index * 4 + 3] = UInt8((alpha * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        if tiles.count >= 32 { tiles.removeAll() }
        tiles[key] = image
        return image
    }
}
