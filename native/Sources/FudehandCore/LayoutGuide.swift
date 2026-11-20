import Foundation

public enum LayoutGuideType: String, Sendable, CaseIterable { case grid, columns, rows }

/// How columns or rows sit in a frame: `stretch` divides the space between the margins, the others keep their width and sit at
/// the start, center, or end.
public enum LayoutGuideAlign: String, Sendable, CaseIterable { case stretch, start, center, end }

/// A grid, columns, or rows drawn over a frame on the editing canvas to align layers to. Never part of snapshots or playback.
/// Columns run along the frame's width and rows along its height; `width` is a column's width or a row's height.
public struct LayoutGuide: Equatable, Sendable {
    public var type: LayoutGuideType
    /// Grid cell size.
    public var size = 10.0
    public var count = 5
    public var align = LayoutGuideAlign.stretch
    /// Ignored when `align` is `stretch`.
    public var width = 60.0
    public var gutter = 20.0
    /// Space from the frame's edge; ignored when `align` is `center`.
    public var margin = 0.0
    public var color = LayoutGuide.defaultColor
    public var visible = true

    public static let defaultColor = DesignColor(r: 1, g: 0, b: 0, a: 26.0 / 255)
    public static let maximumCount = 1000

    public init(type: LayoutGuideType) { self.type = type }

    /// The column or row spans along a length (the frame's width for columns, height for rows); empty for a grid or when the
    /// spans do not fit.
    public func bands(length: Double) -> [ClosedRange<Double>] {
        guard type != .grid, count > 0 else { return [] }
        let gaps = gutter * Double(count - 1)
        let band = align == .stretch ? (length - 2 * margin - gaps) / Double(count) : width
        guard band > 0 else { return [] }
        let total = band * Double(count) + gaps
        let start: Double
        switch align {
        case .stretch, .start: start = margin
        case .center: start = (length - total) / 2
        case .end: start = length - margin - total
        }
        return (0..<count).map { index in
            let lower = start + Double(index) * (band + gutter)
            return lower...(lower + band)
        }
    }

    /// The offsets of a grid's lines inside a length, not counting the frame's own edges; empty for columns and rows.
    public func gridLines(length: Double) -> [Double] { gridLines(length: length, in: 0...length) }

    /// The grid lines that fall within a range of offsets, so drawing a fine grid on a large frame only visits the part on screen.
    public func gridLines(length: Double, in range: ClosedRange<Double>) -> [Double] {
        guard type == .grid, size > 0 else { return [] }
        let first = max(1, (range.lowerBound / size).rounded(.up))
        let last = min(((length / size).rounded(.up)) - 1, (range.upperBound / size).rounded(.down))
        guard first <= last else { return [] }
        return (Int(first)...Int(last)).map { Double($0) * size }
    }

    /// The column or row bands as rectangles in the frame's coordinate space: columns take the frame's full height and rows its
    /// full width.
    public func rects(in frame: Rect) -> [Rect] {
        switch type {
        case .grid: return []
        case .columns: return bands(length: frame.width).map { Rect(x: frame.x + $0.lowerBound, y: frame.y, width: $0.upperBound - $0.lowerBound, height: frame.height) }
        case .rows: return bands(length: frame.height).map { Rect(x: frame.x, y: frame.y + $0.lowerBound, width: frame.width, height: $0.upperBound - $0.lowerBound) }
        }
    }

    /// Zero-thickness rectangles at each band edge, so layers snap to the edges of columns and rows but not to their centers.
    public func snapRects(in frame: Rect) -> [Rect] {
        rects(in: frame).flatMap { band -> [Rect] in
            type == .columns
                ? [Rect(x: band.minX, y: band.y, width: 0, height: band.height), Rect(x: band.maxX, y: band.y, width: 0, height: band.height)]
                : [Rect(x: band.x, y: band.minY, width: band.width, height: 0), Rect(x: band.x, y: band.maxY, width: band.width, height: 0)]
        }
    }
}
