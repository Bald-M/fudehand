import AppKit
import CoreImage
import FudehandCore

/// Builds the Core Animation layers that draw a node's effects (see `DesignEffect`). All of them are laid out in the node's own
/// coordinates, the rectangle (0, 0, width, height). Blur radii are halved into Gaussian standard deviations, as `DesignEffect.radius`
/// documents; Core Animation scales them with the canvas zoom.
@MainActor
enum EffectLayers {
    struct Built {
        /// Drop shadows, drawn under the node in effect order.
        var behind: [CALayer] = []
        /// Background blurs and glass backdrops. Core Animation's background filters only blur the layers drawn before them in the
        /// same superlayer, so these go next to the node in its parent, just under it.
        var backdrops: [CALayer] = []
        /// Inner shadows, noise, textures, shaders, and glass tints and highlights, drawn inside the node above its fill and below its
        /// children, in effect order.
        var inner: [CALayer] = []
        /// Layer blurs, applied to the node with its children and its other effects.
        var filters: [CIFilter] = []
        /// Text or icon copies and shader layers, which need the node's raster scale.
        var copies: [CALayer] = []
        /// A 3D transform, applied to the node (and its background blurs) about its center.
        var transform = CATransform3DIdentity
        /// Perspective, applied to the node's child layers.
        var sublayerTransform = CATransform3DIdentity
    }

    static func build(_ node: DesignNode, scale: CGFloat) -> Built {
        var built = Built()
        let bounds = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        for effect in node.effects where effect.visible {
            switch effect.type {
            case .dropShadow:
                let holder = plain(bounds)
                if let shape = shape(node, spread: effect.spread) {
                    let caster = plain(bounds)
                    caster.shadowPath = shape
                    cast(effect, from: caster)
                    holder.addSublayer(caster)
                    // The shadow is not drawn under the layer itself, so it does not show through a see-through fill.
                    let outside = CAShapeLayer()
                    outside.actions = DesignRenderer.noActions
                    outside.frame = bounds
                    let path = CGMutablePath()
                    path.addRect(bounds.insetBy(dx: -reach(effect), dy: -reach(effect)))
                    path.addPath(self.shape(node, spread: 0) ?? CGPath(rect: bounds, transform: nil))
                    outside.path = path
                    outside.fillRule = .evenOdd
                    holder.mask = outside
                } else {
                    let copy = glyphs(node, scale: scale)
                    copy.position.x += effect.x
                    copy.position.y += effect.y
                    copy.filters = tint(effect, inverted: false) + blur(effect.radius)
                    holder.addSublayer(copy)
                    built.copies.append(copy)
                }
                built.behind.append(holder)
            case .innerShadow:
                let holder = plain(bounds)
                if let shape = shape(node, spread: 0) {
                    clip(holder, to: node, shape: shape)
                    let caster = plain(bounds)
                    let hole = self.shape(node, spread: -effect.spread) ?? CGMutablePath()
                    caster.shadowPath = CGPath(rect: bounds.insetBy(dx: -reach(effect), dy: -reach(effect)), transform: nil).subtracting(hole)
                    cast(effect, from: caster)
                    holder.addSublayer(caster)
                } else {
                    let mask = glyphs(node, scale: scale)
                    holder.mask = mask
                    let copy = glyphs(node, scale: scale)
                    copy.position.x += effect.x
                    copy.position.y += effect.y
                    copy.filters = tint(effect, inverted: true) + blur(effect.radius)
                    holder.addSublayer(copy)
                    built.copies += [mask, copy]
                }
                built.inner.append(holder)
            case .layerBlur:
                built.filters += blur(effect.radius)
            case .backgroundBlur:
                let backdrop = plain(bounds)
                // Core Animation skips a layer that draws nothing, background filters included.
                backdrop.backgroundColor = CGColor(gray: 0, alpha: 0.001)
                backdrop.backgroundFilters = blur(effect.radius)
                if let shape = shape(node, spread: 0) {
                    clip(backdrop, to: node, shape: shape)
                } else {
                    let mask = glyphs(node, scale: scale)
                    backdrop.mask = mask
                    built.copies.append(mask)
                }
                built.backdrops.append(backdrop)
            case .noise:
                // Only frames, rectangles, and ellipses take noise (`EffectType.supports`), so the layer always has a shape.
                guard let shape = shape(node, spread: 0) else { continue }
                let grains = NoiseLayer.make(effect, bounds: bounds)
                clip(grains, to: node, shape: shape)
                // With the inner shadows, in effect order: above the fill, below the child layers.
                built.inner.append(grains)
            case .glass:
                guard let shape = shape(node, spread: 0) else { continue }
                // The backdrop, like a background blur's: the layers under this one in the same parent, saturated, then blurred.
                let backdrop = plain(bounds)
                backdrop.backgroundColor = CGColor(gray: 0, alpha: 0.001)
                backdrop.backgroundFilters = saturate(effect.saturation) + blur(effect.radius)
                clip(backdrop, to: node, shape: shape)
                built.backdrops.append(backdrop)
                let tint = plain(bounds)
                tint.backgroundColor = DesignRenderer.cgColor(effect.color)
                clip(tint, to: node, shape: shape)
                built.inner.append(tint)
                if effect.highlight > 0 { built.inner.append(highlight(node, opacity: effect.highlight)) }
            case .shader:
                guard let shape = shape(node, spread: 0) else { continue }
                let shaded = ShaderLayer()
                shaded.actions = DesignRenderer.noActions
                shaded.frame = bounds
                shaded.contentsScale = scale
                shaded.effect = effect
                shaded.opacity = Float(effect.opacity)
                shaded.compositingFilter = TextureLayer.blendFilter(effect.blend)
                shaded.setNeedsDisplay()
                clip(shaded, to: node, shape: shape)
                built.inner.append(shaded)
                built.copies.append(shaded)
            case .transform3D:
                built.transform = turn(effect)
            case .perspective:
                built.sublayerTransform = perspective(effect, size: bounds.size)
            case .texture:
                guard let shape = shape(node, spread: 0) else { continue }
                let tiles = TextureLayer.make(effect, bounds: bounds)
                clip(tiles, to: node, shape: shape)
                built.inner.append(tiles)
            }
        }
        return built
    }

    /// The outline effects follow, grown by `spread` (shrunk when negative); nil for text and icons, whose effects follow the glyphs.
    static func shape(_ node: DesignNode, spread: Double) -> CGPath? {
        guard node.type != .text, node.type != .icon else { return nil }
        let rect = CGRect(x: 0, y: 0, width: node.width, height: node.height).insetBy(dx: -spread, dy: -spread)
        guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        if node.type == .ellipse { return CGPath(ellipseIn: rect, transform: nil) }
        let corner = node.type.hasCornerRadius ? min(node.cornerRadius, min(node.width, node.height) / 2) : 0
        let radius = max(0, min(corner + spread, min(rect.width, rect.height) / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func plain(_ bounds: CGRect) -> CALayer {
        let layer = CALayer()
        layer.actions = DesignRenderer.noActions
        layer.frame = bounds
        return layer
    }

    /// How far past the layer a shadow can reach.
    private static func reach(_ effect: DesignEffect) -> Double {
        abs(effect.x) + abs(effect.y) + abs(effect.spread) + effect.radius * 2 + 1
    }

    private static func cast(_ effect: DesignEffect, from layer: CALayer) {
        layer.shadowColor = CGColor(srgbRed: effect.color.r, green: effect.color.g, blue: effect.color.b, alpha: 1)
        layer.shadowOpacity = Float(effect.color.a)
        layer.shadowRadius = effect.radius / 2
        layer.shadowOffset = CGSize(width: effect.x, height: effect.y)
    }

    private static func clip(_ layer: CALayer, to node: DesignNode, shape: CGPath) {
        if node.type == .ellipse {
            let mask = CAShapeLayer()
            mask.actions = DesignRenderer.noActions
            mask.path = shape
            layer.mask = mask
        } else {
            layer.cornerRadius = node.type.hasCornerRadius ? min(node.cornerRadius, min(node.width, node.height) / 2) : 0
            layer.masksToBounds = true
        }
    }

    /// A copy of a text or icon layer's glyphs alone, without its background fill or stroke.
    private static func glyphs(_ node: DesignNode, scale: CGFloat) -> CALayer {
        var bare = node
        bare.x = 0
        bare.y = 0
        bare.visible = true
        bare.opacity = 1
        bare.fill = nil
        bare.stroke = nil
        let layer = DesignRenderer.makeLayer(for: node.type, scale: scale)
        DesignRenderer.apply(bare, to: layer, previous: nil, scale: scale)
        return layer
    }

    /// Paints the glyphs in the shadow color; inverted, paints everything but the glyphs.
    private static func tint(_ effect: DesignEffect, inverted: Bool) -> [CIFilter] {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return [] }
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.setValue(zero, forKey: "inputRVector")
        filter.setValue(zero, forKey: "inputGVector")
        filter.setValue(zero, forKey: "inputBVector")
        let alpha = effect.color.a
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: inverted ? -alpha : alpha), forKey: "inputAVector")
        filter.setValue(CIVector(x: effect.color.r, y: effect.color.g, z: effect.color.b, w: inverted ? alpha : 0), forKey: "inputBiasVector")
        return [filter]
    }

    /// As CSS `rotateX() rotateY() translateZ()`: positive rotateX tips the top edge away from the viewer, positive rotateY
    /// turns the right edge away, and positive translateZ moves the layer toward the viewer (`EffectRendererTests` checks each).
    static func turn(_ effect: DesignEffect) -> CATransform3D {
        let radians = { (degrees: Double) in CGFloat(degrees * .pi / 180) }
        var transform = CATransform3DMakeTranslation(0, 0, CGFloat(effect.translateZ))
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(radians(effect.rotateY), 0, 1, 0))
        return CATransform3DConcat(transform, CATransform3DMakeRotation(radians(effect.rotateX), 1, 0, 0))
    }

    /// The children of a layer of `size` seen from `distance` points in front of the point at `originX`, `originY` (fractions
    /// of the size), as CSS `perspective` and `perspective-origin`. Core Animation applies it about the layer's center.
    static func perspective(_ effect: DesignEffect, size: CGSize) -> CATransform3D {
        let dx = CGFloat(effect.originX - 0.5) * size.width, dy = CGFloat(effect.originY - 0.5) * size.height
        var depth = CATransform3DIdentity
        depth.m34 = -1 / CGFloat(effect.distance)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0), depth), CATransform3DMakeTranslation(dx, dy, 0))
    }

    private static func saturate(_ amount: Double) -> [CIFilter] {
        guard amount != 1, let filter = CIFilter(name: "CIColorControls") else { return [] }
        filter.setValue(amount, forKey: kCIInputSaturationKey)
        return [filter]
    }

    /// Glass's light edge: a 1 pt white line just inside the shape, strongest at the top and gone by the middle.
    private static func highlight(_ node: DesignNode, opacity: Double) -> CALayer {
        let bounds = CGRect(x: 0, y: 0, width: node.width, height: node.height)
        let edge = CAShapeLayer()
        edge.actions = DesignRenderer.noActions
        edge.frame = bounds
        edge.path = shape(node, spread: -0.5)
        edge.fillColor = nil
        edge.strokeColor = CGColor(gray: 1, alpha: opacity)
        edge.lineWidth = 1
        let fade = CAGradientLayer()
        fade.actions = DesignRenderer.noActions
        fade.frame = bounds
        fade.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fade.locations = [0, 0.5]
        edge.mask = fade
        return edge
    }

    private static func blur(_ radius: Double) -> [CIFilter] {
        guard radius > 0, let filter = CIFilter(name: "CIGaussianBlur") else { return [] }
        filter.setValue(radius / 2, forKey: kCIInputRadiusKey)
        return [filter]
    }
}
