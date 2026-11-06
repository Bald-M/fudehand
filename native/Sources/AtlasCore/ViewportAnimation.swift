import Foundation

public enum ViewportAnimation {
    public static let duration = 0.2

    /// Cubic ease-out: 1 - (1 - t)^3, with `t` clamped to [0, 1].
    public static func easeOut(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return 1 - pow(1 - c, 3)
    }

    /// Interpolates between two viewports: scale in log space, and the world point at the
    /// viewport center linearly, so zooming stays centered while panning. `fraction` is already eased.
    public static func value(from: Viewport, to: Viewport, size: Size, fraction: Double) -> Viewport {
        if fraction <= 0 { return from }
        if fraction >= 1 { return to }
        let scale = exp(log(from.scale) + (log(to.scale) - log(from.scale)) * fraction)
        let fromCenter = CanvasGeometry.screenToWorld(Point(x: size.width / 2, y: size.height / 2), viewport: from)
        let toCenter = CanvasGeometry.screenToWorld(Point(x: size.width / 2, y: size.height / 2), viewport: to)
        let cx = fromCenter.x + (toCenter.x - fromCenter.x) * fraction
        let cy = fromCenter.y + (toCenter.y - fromCenter.y) * fraction
        return Viewport(x: size.width / 2 - cx * scale, y: size.height / 2 - cy * scale, scale: scale)
    }
}
