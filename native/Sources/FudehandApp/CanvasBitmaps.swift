import AppKit
import FudehandCore

/// Bitmaps of top-level layers with effects, drawn in place of their live layers while the canvas pans or zooms (#241).
///
/// Core Animation computes every background filter (glass, background blur) and layer blur again on each frame the view
/// moves, which costs hundreds of milliseconds per frame on a design with a few hundred of them. Moving the view does not
/// change what a top-level layer looks like, so a bitmap of it, drawn once by Core Animation itself (as snapshots are),
/// shows the same pixels and only needs moving. Bitmaps are drawn one at a time while the canvas is idle, kept while their
/// node is unchanged, and drawn again at a new zoom; a stale one is never shown.
@MainActor
final class CanvasBitmaps {
    private struct Entry {
        let node: DesignNode
        let scale: CGFloat
        let layer: CALayer
    }

    /// The longest side of a bitmap in pixels; larger layers are drawn at a lower scale.
    static let maximumPixels: CGFloat = 4096
    private var entries: [String: Entry] = [:]

    /// The bitmap layer last drawn for a node, current or not.
    func layer(for id: String) -> CALayer? { entries[id]?.layer }

    /// Whether a top-level node is drawn as a bitmap while the view moves: it is visible, it or a descendant has a visible
    /// effect, its paint is bounded, and it has no background blur or glass of its own, which shows the layers behind it.
    static func wanted(_ node: DesignNode) -> Bool {
        guard node.visible, hasEffects(node), node.paintBounds != nil else { return false }
        return !node.effects.contains { $0.visible && ($0.type == .glass || $0.type == .backgroundBlur) }
    }

    private static func hasEffects(_ node: DesignNode) -> Bool {
        node.effects.contains(where: \.visible) || node.children.contains { $0.visible && hasEffects($0) }
    }

    /// The bitmaps that show the top-level `nodes` as they are now, at `scale`, by node id.
    func current(_ nodes: [DesignNode], scale: CGFloat) -> [String: CALayer] {
        var current: [String: CALayer] = [:]
        for node in nodes {
            if let entry = entries[node.id], entry.scale == scale, entry.node == node, entry.layer.contents != nil {
                current[node.id] = entry.layer
            }
        }
        return current
    }

    /// Draws the bitmap of the wanted node nearest the middle of `near` (world coordinates) that has no current one, and
    /// forgets bitmaps of nodes that are gone or whose paint misses `near`. Returns false when there was nothing to draw.
    func drawNext(_ nodes: [DesignNode], near: CGRect, scale: CGFloat) -> Bool {
        var kept: Set<String> = []
        var candidates: [(distance: CGFloat, node: DesignNode, paint: CGRect)] = []
        for node in nodes where Self.wanted(node) {
            guard let bounds = node.paintBounds else { continue }
            let paint = CGRect(x: node.x + bounds.x, y: node.y + bounds.y, width: bounds.width, height: bounds.height)
            guard paint.intersects(near) else { continue }
            kept.insert(node.id)
            if let entry = entries[node.id], entry.scale == scale, entry.node == node { continue }
            candidates.append((hypot(paint.midX - near.midX, paint.midY - near.midY), node, paint))
        }
        entries = entries.filter { kept.contains($0.key) }
        guard let next = candidates.min(by: { $0.distance < $1.distance }) else { return false }
        let pixels = min(scale, Self.maximumPixels / max(next.paint.width, next.paint.height, 1))
        let local = next.paint.offsetBy(dx: -next.node.x, dy: -next.node.y)
        let layer = entries[next.node.id]?.layer ?? {
            let layer = CALayer()
            layer.actions = DesignRenderer.noActions
            return layer
        }()
        // Drawn before the transaction below opens: the offscreen renderer draws only committed layers.
        // A node that cannot be drawn keeps an empty entry, so it is not tried again until it changes, and stays live.
        let image = try? DesignRenderer.image(of: next.node, in: local, scale: pixels)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = next.paint
        layer.contents = image
        CATransaction.commit()
        entries[next.node.id] = Entry(node: next.node, scale: scale, layer: layer)
        return true
    }

    func removeAll() { entries = [:] }
}
