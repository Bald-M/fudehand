import AppKit
import FudehandCore

/// The layer of an icon node. The icon's shape comes from its library (bundled SVG, or SF Symbols from the system), is drawn
/// aspect-fit and centered for the size it is shown at, and tinted with the icon color into `contents`. Like an SVG image it is
/// drawn again when the zoom settles or the layer grows, so it stays sharp. Tinting into `contents` rather than using a mask keeps
/// `render(in:)` snapshots working, which ignore masks. An icon its library does not have draws a placeholder.
final class IconLayer: CALayer {
    private var icon: DesignIcon?
    private var shape: NSImage?
    /// The pixel size of the current raster.
    private var raster: CGSize = .zero
    private(set) var isPlaceholder = false

    @MainActor func update(_ icon: DesignIcon) {
        guard icon != self.icon else { return rasterize(force: false) }
        if icon.name != self.icon?.name { shape = Self.shape(icon.name) }
        self.icon = icon
        isPlaceholder = shape == nil
        rasterize(force: true)
    }

    @MainActor static func shape(_ name: String) -> NSImage? {
        if let svg = IconCatalog.shared.svg(name) { return NSImage(data: svg) }
        guard let (library, symbol) = IconLibrary.parse(name), library == .sf else { return nil }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// Draws the bounds × `contentsScale`. Unless forced, only when that is larger than the current raster or has another aspect
    /// ratio, and then with 1.5× headroom, as `ImageLayer` does.
    @MainActor func rasterize(force: Bool) {
        guard icon != nil, bounds.width > 0, bounds.height > 0 else { return }
        let limit = DesignRenderer.maximumRasterSide / max(bounds.width, bounds.height)
        let needed = min(contentsScale, limit)
        let aspectChanged = raster.height > 0 && abs(raster.width / raster.height - bounds.width / bounds.height) > 0.01
        guard force || aspectChanged || bounds.width * needed > raster.width.rounded(.up) + 0.5 || bounds.height * needed > raster.height.rounded(.up) + 0.5
        else { return }
        let factor = force || aspectChanged ? needed : min(needed * 1.5, limit)
        let pixels = CGSize(width: max(1, (bounds.width * factor).rounded(.up)), height: max(1, (bounds.height * factor).rounded(.up)))
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        if let shape, let color = DesignRenderer.cgColor(icon?.color) {
            draw(shape, in: context, size: pixels)
            context.setBlendMode(.sourceIn)
            context.setFillColor(color)
            context.fill(CGRect(origin: .zero, size: pixels))
        } else {
            drawPlaceholder(in: context, size: pixels, scale: factor)
        }
        contents = context.makeImage()
        contentsGravity = .resize
        raster = pixels
    }

    /// An SF Symbol is drawn at a point size of 3/4 of the layer's shorter side (in pixels here), which leaves an optical
    /// margin like the padded 24 × 24 artboards of the bundled libraries; it is only shrunk if it would still overflow. A
    /// bundled icon's SVG already carries its margin and is fitted to the layer.
    private func draw(_ shape: NSImage, in context: CGContext, size: CGSize) {
        var image = shape
        if icon.flatMap({ IconLibrary.parse($0.name)?.library }) == .sf,
           let configured = shape.withSymbolConfiguration(.init(pointSize: min(size.width, size.height) * 0.75, weight: .regular)) {
            image = configured
        }
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return }
        let fit = image === shape ? min(size.width / natural.width, size.height / natural.height)
                                  : min(1, size.width / natural.width, size.height / natural.height)
        let drawn = CGSize(width: natural.width * fit, height: natural.height * fit)
        let rect = CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A light gray box with a diagonal line, the conventional sign of missing content.
    private func drawPlaceholder(in context: CGContext, size: CGSize, scale: CGFloat) {
        let rect = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(gray: 0, alpha: 0.1))
        context.fill(rect)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.3))
        context.setLineWidth(scale)
        context.stroke(rect.insetBy(dx: scale / 2, dy: scale / 2))
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: size.width, y: size.height))
        context.strokePath()
    }
}
