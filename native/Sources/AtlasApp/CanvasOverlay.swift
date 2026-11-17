import AppKit
import AtlasCore

/// Screen-space decorations drawn above the frames: hover, selection, active frame, marquee and snap guides.
/// It never takes pointer input.
final class CanvasOverlay: NSView {
    override var isFlipped: Bool { true }
    private let hoverLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let activeLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private static let cornerRadius = 10.0
    private static let activeOutset = 4.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverLayer.lineWidth = 1
        selectionLayer.lineWidth = 2
        activeLayer.lineWidth = 1
        marqueeLayer.lineWidth = 1
        guideLayer.lineWidth = 1
        for shape in [hoverLayer, selectionLayer, activeLayer, marqueeLayer, guideLayer] {
            shape.fillColor = nil
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(shape)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Screen-space bounds of the drawn selection outlines; `.null` when nothing is selected.
    var selectionBounds: CGRect { selectionLayer.path?.boundingBoxOfPath ?? .null }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [hoverLayer, selectionLayer, activeLayer, marqueeLayer, guideLayer] { shape.frame = bounds }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            hoverLayer.strokeColor = accent.cgColor
            selectionLayer.strokeColor = accent.cgColor
            activeLayer.strokeColor = accent.withAlphaComponent(0.5).cgColor
            marqueeLayer.strokeColor = accent.cgColor
            marqueeLayer.fillColor = accent.withAlphaComponent(0.12).cgColor
            guideLayer.strokeColor = NSColor.systemRed.cgColor
        }
    }

    /// `frames` and `guides` are in world coordinates; `marquee` is already in screen coordinates.
    func render(viewport: Viewport, frames: [String: Rect], selection: Set<String>, active: String?, hover: String?,
                marquee: Rect?, guides: [Guide]) {
        func screen(_ rect: Rect) -> NSRect {
            NSRect(x: rect.x * viewport.scale + viewport.x, y: rect.y * viewport.scale + viewport.y,
                   width: rect.width * viewport.scale, height: rect.height * viewport.scale)
        }
        let radius = Self.cornerRadius * viewport.scale
        func outline(_ ids: [String], outset: Double = 0) -> CGPath {
            let path = CGMutablePath()
            for id in ids {
                guard let rect = frames[id] else { continue }
                let r = screen(rect).insetBy(dx: -outset, dy: -outset)
                path.addRoundedRect(in: r, cornerWidth: radius + outset, cornerHeight: radius + outset)
            }
            return path
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.path = outline(hover.flatMap { selection.contains($0) ? nil : [$0] } ?? [])
        selectionLayer.path = outline(Array(selection))
        activeLayer.path = outline(active.map { [$0] } ?? [], outset: Self.activeOutset)
        marqueeLayer.path = marquee.map {
            CGPath(rect: NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height), transform: nil)
        }
        let guidePath = CGMutablePath()
        for guide in guides {
            let s = viewport.scale
            switch guide.axis {
            case .vertical:
                let x = guide.position * s + viewport.x
                guidePath.move(to: CGPoint(x: x, y: guide.start * s + viewport.y))
                guidePath.addLine(to: CGPoint(x: x, y: guide.end * s + viewport.y))
            case .horizontal:
                let y = guide.position * s + viewport.y
                guidePath.move(to: CGPoint(x: guide.start * s + viewport.x, y: y))
                guidePath.addLine(to: CGPoint(x: guide.end * s + viewport.x, y: y))
            }
        }
        guideLayer.path = guidePath
        CATransaction.commit()
    }
}
