import AppKit
import FudehandCore

/// Bitmaps of top-level layers with effects, drawn in place of their live layers while the canvas pans or zooms (#241).
///
/// Core Animation computes every background filter (glass, background blur) and layer blur again on each frame the view
/// moves, which costs hundreds of milliseconds per frame on a design with a few hundred of them. Moving the view does not
/// change what a top-level layer looks like, so a bitmap of it, drawn once by Core Animation itself (as snapshots are),
/// shows the same pixels and only needs moving. Bitmaps are drawn one at a time while the canvas is idle, mostly off the main
/// thread (#243), kept while their node is unchanged and they fit the pixel budget, and drawn again at a new zoom (until
/// then the old one is shown stretched); one of a node that has changed since is never shown.
@MainActor
final class CanvasBitmaps {
    private struct Entry {
        let node: DesignNode
        let scale: CGFloat
        let layer: CALayer
        let pixels: Int
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

    /// The bitmaps that show the top-level `nodes` as they are now, by node id; drawn at any zoom.
    func current(_ nodes: [DesignNode]) -> [String: CALayer] {
        var current: [String: CALayer] = [:]
        for node in nodes {
            if let entry = entries[node.id], entry.node == node, entry.layer.contents != nil { current[node.id] = entry.layer }
        }
        return current
    }

    /// Starts drawing the bitmap of the wanted node nearest the middle of `near` (world coordinates) that has none showing it
    /// as it is now at `scale`, and forgets bitmaps of nodes that are gone or whose paint misses `near`. With `onlyMissing`
    /// (while the view moves), a node whose bitmap is only at another zoom is left for later.
    ///
    /// The layers are built here, on the main thread; Core Animation renders them, the GPU finishes, and the pixels are read
    /// back on a background queue, and `finished` runs on the main thread once the bitmap is in place (#243). One bitmap is
    /// drawn at a time. Returns the seconds the main thread spent starting it, or nil when nothing was started: one is still
    /// being drawn, none is missing, or the next would not fit `pixelBudget` beside the bitmaps nearer the middle.
    func drawNext(_ nodes: [DesignNode], near: CGRect, scale: CGFloat, onlyMissing: Bool = false,
                  finished: @escaping @MainActor () -> Void) -> CFTimeInterval? {
        guard !drawing else { return nil }
        let start = CACurrentMediaTime()
        var distances: [String: CGFloat] = [:]
        var candidates: [(distance: CGFloat, node: DesignNode, paint: CGRect)] = []
        for node in nodes where Self.wanted(node) {
            guard let bounds = node.paintBounds else { continue }
            let paint = CGRect(x: node.x + bounds.x, y: node.y + bounds.y, width: bounds.width, height: bounds.height)
            guard paint.intersects(near) else { continue }
            let distance = hypot(paint.midX - near.midX, paint.midY - near.midY)
            distances[node.id] = distance
            if let entry = entries[node.id], entry.node == node, entry.scale == scale || onlyMissing { continue }
            candidates.append((distance, node, paint))
        }
        entries = entries.filter { distances[$0.key] != nil }
        lastDistances = distances
        guard let next = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        let pixels = min(scale, Self.maximumPixels / max(next.paint.width, next.paint.height, 1))
        let cost = Int((next.paint.width * pixels).rounded(.up) * (next.paint.height * pixels).rounded(.up))
        let nearer = entries.filter { $0.key != next.node.id && (distances[$0.key] ?? .infinity) < next.distance }.values.reduce(0) { $0 + $1.pixels }
        guard nearer + cost <= pixelBudget else { return nil }
        let local = next.paint.offsetBy(dx: -next.node.x, dy: -next.node.y)
        let layer = entries[next.node.id]?.layer ?? {
            let layer = CALayer()
            layer.actions = DesignRenderer.noActions
            return layer
        }()
        let job = try? OffscreenImage(of: next.node, in: local, scale: pixels)
        drawing = true
        let generation = self.generation
        let install: @MainActor (CGImage?) -> Void = { [weak self] image in
            guard let self else { return }
            self.drawing = false
            // Dropped meanwhile (fonts changed): the bitmap may show the old fonts.
            if generation == self.generation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // The bitmap's whole pixels cover a little more than the paint bounds; the layer matches them, so nothing is stretched.
                layer.frame = CGRect(origin: next.paint.origin,
                                     size: image.map { CGSize(width: CGFloat($0.width) / pixels, height: CGFloat($0.height) / pixels) } ?? next.paint.size)
                // A node that cannot be drawn keeps an empty entry, so it is not tried again until it changes, and stays live.
                layer.contents = image
                CATransaction.commit()
                self.entries[next.node.id] = Entry(node: next.node, scale: scale, layer: layer, pixels: image.map { $0.width * $0.height } ?? 0)
                self.keepToBudget()
            }
            finished()
        }
        if let job {
            // Only the main thread lets go of the job, and with it the layers, which the main thread built.
            let hold = JobHold(job)
            DispatchQueue.global(qos: .utility).async {
                let image = try? hold.job?.draw()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        hold.job = nil
                        install(image)
                    }
                }
            }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { install(nil) } }
        }
        return CACurrentMediaTime() - start
    }

    /// Whether a bitmap is being drawn.
    private(set) var drawing = false
    /// How many pixels the bitmaps may hold together, 4 bytes each: 32 million is 128 MB.
    var pixelBudget = 32 * 1024 * 1024
    /// How many pixels the bitmaps hold.
    var pixelCount: Int { entries.values.reduce(0) { $0 + $1.pixels } }
    /// Each kept node's distance from the middle of the last `near`, for choosing which bitmaps to drop.
    private var lastDistances: [String: CGFloat] = [:]
    /// Bumped by `removeAll`, so a bitmap still being drawn is not kept.
    private var generation = 0

    /// Drops the bitmaps farthest from the middle of the view until the rest fit `pixelBudget`.
    private func keepToBudget() {
        var total = pixelCount
        for (id, entry) in entries.sorted(by: { (lastDistances[$0.key] ?? .infinity) > (lastDistances[$1.key] ?? .infinity) }) {
            guard total > pixelBudget else { break }
            entries[id] = nil
            total -= entry.pixels
        }
    }

    func removeAll() {
        entries = [:]
        generation += 1
    }
}

/// Holds an `OffscreenImage` for the background queue that draws it, while the main thread decides when it is released.
private final class JobHold: @unchecked Sendable {
    var job: OffscreenImage?
    init(_ job: OffscreenImage) { self.job = job }
}
