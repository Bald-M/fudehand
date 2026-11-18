import AppKit
import FudehandCore

/// The canvas dot grid: one dot replicated along a row, and that row replicated down the canvas.
/// Panning only moves the replicated block by the grid phase; no sublayers are rebuilt.
final class CanvasGrid: CALayer {
    static let baseSpacing = 32.0
    static let minimumSpacing = 8.0
    static let dotSize = 1.5
    private let rows = CAReplicatorLayer()
    private let row = CAReplicatorLayer()
    private let dot = CALayer()

    override init() {
        super.init()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        dot.cornerRadius = Self.dotSize / 2
        rows.anchorPoint = .zero
        row.addSublayer(dot)
        rows.addSublayer(row)
        addSublayer(rows)
        CATransaction.commit()
    }

    /// Core Animation copies layers for presentation; the copy needs no sublayer setup.
    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `bounds` is the canvas rect in its (flipped) coordinates.
    func update(viewport: Viewport, bounds: CGRect) {
        let spacing = Self.baseSpacing * viewport.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        frame = bounds
        isHidden = spacing < Self.minimumSpacing
        guard !isHidden else { return }
        let columns = Int((bounds.width / spacing).rounded(.up)) + 2
        let lines = Int((bounds.height / spacing).rounded(.up)) + 2
        if row.instanceCount != columns { row.instanceCount = columns }
        if rows.instanceCount != lines { rows.instanceCount = lines }
        row.instanceTransform = CATransform3DMakeTranslation(spacing, 0, 0)
        rows.instanceTransform = CATransform3DMakeTranslation(0, spacing, 0)
        // Dots sit at viewport.x + k·spacing; start one spacing before the edge so it is always covered.
        func phase(_ offset: Double) -> Double {
            let r = offset.truncatingRemainder(dividingBy: spacing)
            return (r < 0 ? r + spacing : r) - spacing
        }
        rows.position = CGPoint(x: phase(viewport.x), y: phase(viewport.y))
    }

    /// Resolves the dynamic separator color under `appearance`.
    func updateColor(for appearance: NSAppearance) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        appearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        }
        CATransaction.commit()
    }
}
