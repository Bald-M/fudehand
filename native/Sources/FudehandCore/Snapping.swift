import Foundation

/// An alignment guide line in canvas coordinates.
/// `.vertical` is a line at fixed x (`position`) spanning y from `start` to `end`; `.horizontal` is the transpose.
public struct Guide: Equatable {
    public enum Axis: Equatable { case vertical, horizontal }
    public var axis: Axis
    public var position: Double
    public var start: Double
    public var end: Double
    public init(axis: Axis, position: Double, start: Double, end: Double) {
        self.axis = axis; self.position = position; self.start = start; self.end = end
    }
}

public enum Snapping {
    private static let tolerance = 0.001

    /// Snaps `moving` to the min/mid/max edges of `others` on each axis independently.
    /// Returns the offset to apply to `moving` and the guides that show the resulting alignments.
    public static func snap(_ moving: Rect, to others: [Rect], threshold: Double) -> (offset: Point, guides: [Guide]) {
        let dx = bestDelta(moving.minX, moving.midX, moving.maxX, others.map { ($0.minX, $0.midX, $0.maxX) }, threshold)
        let dy = bestDelta(moving.minY, moving.midY, moving.maxY, others.map { ($0.minY, $0.midY, $0.maxY) }, threshold)
        let moved = moving.offsetBy(Point(x: dx ?? 0, y: dy ?? 0))

        var guides: [Guide] = []
        func append(_ guide: Guide) { if !guides.contains(guide) { guides.append(guide) } }
        if let dx {
            for other in others {
                for (m, o) in pairs([moving.minX, moving.midX, moving.maxX], [other.minX, other.midX, other.maxX])
                where abs((o - m) - dx) <= tolerance {
                    append(Guide(axis: .vertical, position: o,
                                        start: min(moved.minY, other.minY), end: max(moved.maxY, other.maxY)))
                }
            }
        }
        if let dy {
            for other in others {
                for (m, o) in pairs([moving.minY, moving.midY, moving.maxY], [other.minY, other.midY, other.maxY])
                where abs((o - m) - dy) <= tolerance {
                    append(Guide(axis: .horizontal, position: o,
                                        start: min(moved.minX, other.minX), end: max(moved.maxX, other.maxX)))
                }
            }
        }
        return (Point(x: dx ?? 0, y: dy ?? 0), guides)
    }

    /// Snaps only the edges a resize handle drags to the min/mid/max edges of `others`; the opposite edges stay put.
    /// Returns the adjusted rectangle and the guides that show the resulting alignments.
    public static func snapEdges(_ rect: Rect, handle: ResizeHandle, to others: [Rect], threshold: Double) -> (rect: Rect, guides: [Guide]) {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        func delta(_ edge: Double, _ edges: (Rect) -> (Double, Double, Double)) -> Double? {
            bestDelta(edge, edge, edge, others.map(edges), threshold)
        }
        var vertical: Double?, horizontal: Double?
        // An axis whose snap would leave the rectangle under the handles' minimum size of 1 (or flip it) is left unsnapped.
        if handle.movesLeft, let d = delta(left, { ($0.minX, $0.midX, $0.maxX) }), right - (left + d) >= 1 { left += d; vertical = left }
        if handle.movesRight, let d = delta(right, { ($0.minX, $0.midX, $0.maxX) }), right + d - left >= 1 { right += d; vertical = right }
        if handle.movesTop, let d = delta(top, { ($0.minY, $0.midY, $0.maxY) }), bottom - (top + d) >= 1 { top += d; horizontal = top }
        if handle.movesBottom, let d = delta(bottom, { ($0.minY, $0.midY, $0.maxY) }), bottom + d - top >= 1 { bottom += d; horizontal = bottom }
        let snapped = Rect(x: left, y: top, width: right - left, height: bottom - top)
        var guides: [Guide] = []
        func append(_ guide: Guide) { if !guides.contains(guide) { guides.append(guide) } }
        for other in others {
            if let x = vertical, [other.minX, other.midX, other.maxX].contains(where: { abs($0 - x) <= tolerance }) {
                append(Guide(axis: .vertical, position: x, start: min(snapped.minY, other.minY), end: max(snapped.maxY, other.maxY)))
            }
            if let y = horizontal, [other.minY, other.midY, other.maxY].contains(where: { abs($0 - y) <= tolerance }) {
                append(Guide(axis: .horizontal, position: y, start: min(snapped.minX, other.minX), end: max(snapped.maxX, other.maxX)))
            }
        }
        return (snapped, guides)
    }

    /// Every (moving edge, other edge) combination, regardless of edge kind.
    private static func pairs(_ moving: [Double], _ others: [Double]) -> [(Double, Double)] {
        moving.flatMap { m in others.map { (m, $0) } }
    }

    /// Smallest-magnitude difference within the threshold; ties keep the first candidate.
    private static func bestDelta(_ a: Double, _ b: Double, _ c: Double,
                                  _ others: [(Double, Double, Double)], _ threshold: Double) -> Double? {
        var best: Double?
        for other in others {
            for o in [other.0, other.1, other.2] {
                for m in [a, b, c] {
                    let d = o - m
                    if abs(d) <= threshold, best == nil || abs(d) < abs(best!) { best = d }
                }
            }
        }
        return best
    }
}
