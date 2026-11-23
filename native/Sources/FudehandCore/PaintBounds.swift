extension DesignNode {
    /// The rectangle this node and its visible descendants can paint into, in the node's own coordinates (its top-left corner
    /// is 0, 0), drop shadows and layer blurs included; nil when a 3D transform or a perspective can put pixels anywhere. A
    /// frame that clips its content keeps its children inside its own rectangle. Effects that draw inside the shape (inner
    /// shadows, noise, textures, glass, background blurs, shaders) add nothing.
    public var paintBounds: Rect? {
        var minX = 0.0, minY = 0.0, maxX = width, maxY = height
        if !(type == .frame && clipsContent) {
            for child in children where child.visible {
                guard let painted = child.paintBounds else { return nil }
                minX = min(minX, child.x + painted.minX)
                minY = min(minY, child.y + painted.minY)
                maxX = max(maxX, child.x + painted.maxX)
                maxY = max(maxY, child.y + painted.maxY)
            }
        }
        var reach = 0.0
        for effect in effects where effect.visible {
            switch effect.type {
            case .transform3D, .perspective:
                return nil
            // A Gaussian with standard deviation radius / 2 fades out within 1.5 × radius; 2 × radius leaves a margin.
            case .dropShadow:
                reach = max(reach, abs(effect.x) + abs(effect.y) + abs(effect.spread) + 2 * effect.radius)
            case .layerBlur:
                reach = max(reach, 2 * effect.radius)
            case .innerShadow, .backgroundBlur, .noise, .texture, .glass, .shader:
                break
            }
        }
        return Rect(x: minX - reach, y: minY - reach, width: maxX - minX + 2 * reach, height: maxY - minY + 2 * reach)
    }
}
