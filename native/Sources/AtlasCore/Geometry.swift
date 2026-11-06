import Foundation

public struct Point: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Viewport: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var scale: Double
    public init(x: Double = 0, y: Double = 0, scale: Double = 1) {
        self.x = x; self.y = y; self.scale = scale
    }
}

public struct Size: Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct Rect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum CanvasGeometry {
    public static let minScale = 0.1
    public static let maxScale = 2.0
    public static let headerHeight = 44.0
    /// Points per notch for a line-based mouse wheel, matching the browser canvas.
    public static let wheelLineHeight = 16.0

    public static func wheelDelta(_ delta: Point, precise: Bool) -> Point {
        precise ? delta : Point(x: delta.x * wheelLineHeight, y: delta.y * wheelLineHeight)
    }

    public static func screenToWorld(_ point: Point, viewport: Viewport) -> Point {
        Point(x: (point.x - viewport.x) / viewport.scale, y: (point.y - viewport.y) / viewport.scale)
    }

    public static func zoomAt(_ viewport: Viewport, point: Point, scale: Double) -> Viewport {
        let next = min(maxScale, max(minScale, scale))
        let world = screenToWorld(point, viewport: viewport)
        return Viewport(x: point.x - world.x * next, y: point.y - world.y * next, scale: next)
    }

    public static func moveFrame(_ start: Point, screenDelta: Point, scale: Double) -> Point {
        Point(x: start.x + screenDelta.x / scale, y: start.y + screenDelta.y / scale)
    }

    public static func fitRects(_ rects: [Rect], size: Size, padding: Double = 64) -> Viewport {
        guard !rects.isEmpty, size.width > 0, size.height > 0 else { return Viewport() }
        let left = rects.map(\.x).min()!
        let top = rects.map(\.y).min()!
        let right = rects.map { $0.x + $0.width }.max()!
        let bottom = rects.map { $0.y + $0.height }.max()!
        let requested = min(max(1, size.width - padding * 2) / max(1, right - left),
                            max(1, size.height - padding * 2) / max(1, bottom - top))
        let scale = min(1, max(minScale, min(maxScale, requested)))
        return Viewport(x: (size.width - (right - left) * scale) / 2 - left * scale,
                        y: (size.height - (bottom - top) * scale) / 2 - top * scale, scale: scale)
    }
}
