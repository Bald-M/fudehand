import AppKit
import CoreImage
import FudehandCore

/// Draws a texture effect: its image repeated across the layer from the top-left corner, each repeat `size` points wide. To keep
/// the layer count low however small the tiles are, the tile is drawn once into a block at least `minimumBlock` points on each
/// side, and the block is what repeats. The holder carries the effect's opacity and blend, so the blend applies against the
/// layer's fill and what is drawn under the texture inside the layer.
@MainActor
enum TextureLayer {
    static let minimumBlock: CGFloat = 256
    /// The longest side of a block's bitmap in pixels.
    static let maximumPixels: CGFloat = 4096

    static func make(_ effect: DesignEffect, bounds: CGRect) -> CALayer {
        let holder = CALayer()
        holder.actions = DesignRenderer.noActions
        holder.frame = bounds
        holder.opacity = Float(effect.opacity)
        holder.compositingFilter = blendFilter(effect.blend)
        guard let data = effect.texture, let block = block(data, width: effect.size) else { return holder }
        var top: CGFloat = 0
        while top < bounds.height {
            var left: CGFloat = 0
            while left < bounds.width {
                let repeated = CALayer()
                repeated.actions = DesignRenderer.noActions
                repeated.frame = CGRect(x: left, y: top, width: block.size.width, height: block.size.height)
                repeated.contents = block.image
                holder.addSublayer(repeated)
                left += block.size.width
            }
            top += block.size.height
        }
        return holder
    }

    static func blendFilter(_ blend: TextureBlend) -> CIFilter? {
        switch blend {
        case .normal: return nil
        case .multiply: return CIFilter(name: "CIMultiplyBlendMode")
        case .screen: return CIFilter(name: "CIScreenBlendMode")
        case .overlay: return CIFilter(name: "CIOverlayBlendMode")
        case .softLight: return CIFilter(name: "CISoftLightBlendMode")
        }
    }

    struct Block { let image: CGImage, size: CGSize }
    private struct Key: Hashable { let data: Data, width: Double }
    private static var blocks: [Key: Block] = [:]

    /// The tile repeated into a block, made once per image and tile width. A bitmap keeps its own pixel density (an SVG is
    /// rasterized at 3 pixels per point), within `maximumPixels`.
    static func block(_ data: Data, width: Double) -> Block? {
        let key = Key(data: data, width: width)
        if let cached = blocks[key] { return cached }
        let bitmap = DesignRenderer.cgImage(data)
        guard let natural = bitmap.map({ CGSize(width: $0.width, height: $0.height) }) ?? DesignRenderer.svgImage(data)?.size,
              natural.width > 0, natural.height > 0 else { return nil }
        let tile = CGSize(width: width, height: width * natural.height / natural.width)
        let across = ceil(minimumBlock / tile.width), down = ceil(minimumBlock / tile.height)
        // An extremely flat or narrow image would need tens of thousands of tiles per block; it draws nothing instead.
        guard across * down <= 16_384 else { return nil }
        let size = CGSize(width: tile.width * across, height: tile.height * down)
        let wanted = bitmap.map { CGFloat($0.width) / tile.width } ?? 3
        let density = max(1, min(wanted, maximumPixels / size.width, maximumPixels / size.height))
        let pixels = (width: Int((size.width * density).rounded(.up)), height: Int((size.height * density).rounded(.up)))
        guard let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: density, y: density)
        context.interpolationQuality = .high
        // The context has a bottom-left origin; rows are laid out from the top so the first tile sits at the block's top-left.
        for row in 0..<Int(down) {
            for column in 0..<Int(across) {
                let rect = CGRect(x: CGFloat(column) * tile.width, y: size.height - CGFloat(row + 1) * tile.height,
                                  width: tile.width, height: tile.height)
                if let bitmap {
                    context.draw(bitmap, in: rect)
                } else if let svg = DesignRenderer.svgImage(data) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    svg.draw(in: rect)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
        guard let image = context.makeImage() else { return nil }
        if blocks.count >= 16 { blocks.removeAll() }
        let block = Block(image: image, size: size)
        blocks[key] = block
        return block
    }
}
