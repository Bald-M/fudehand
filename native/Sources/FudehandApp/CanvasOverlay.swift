import AppKit
import FudehandCore

/// Screen-space decorations drawn above the layers: hover, selection box, resize handles, top-level frame names, marquee selection, and snapping guides. Never receives pointer input.
final class CanvasOverlay: NSView {
    override var isFlipped: Bool { true }
    private let hoverLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let labelHost = CALayer()
    private var labels: [String: CATextLayer] = [:]
    static let handleSize = 7.0
    static let handleHitRadius = 6.0
    static let labelHeight = 16.0
    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverLayer.lineWidth = 1
        selectionLayer.lineWidth = 1.5
        handleLayer.lineWidth = 1
        marqueeLayer.lineWidth = 1
        guideLayer.lineWidth = 1
        for shape in [hoverLayer, selectionLayer, handleLayer, marqueeLayer, guideLayer] {
            shape.fillColor = nil
            shape.actions = DesignRenderer.noActions
            layer?.addSublayer(shape)
        }
        labelHost.actions = DesignRenderer.noActions
        layer?.insertSublayer(labelHost, at: 0)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Screen-space bounds of the drawn selection outlines; `.null` when nothing is selected.
    var selectionBounds: CGRect { selectionLayer.path?.boundingBoxOfPath ?? .null }
    var labelTexts: [String: String] { labels.compactMapValues { $0.string as? String } }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [hoverLayer, selectionLayer, handleLayer, marqueeLayer, guideLayer, labelHost] { shape.frame = bounds }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private var accent = NSColor.controlAccentColor.cgColor
    private var secondary = NSColor.secondaryLabelColor.cgColor

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.cgColor
            secondary = NSColor.secondaryLabelColor.cgColor
            hoverLayer.strokeColor = accent
            selectionLayer.strokeColor = accent
            handleLayer.strokeColor = accent
            handleLayer.fillColor = NSColor.white.cgColor
            marqueeLayer.strokeColor = accent
            marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            guideLayer.strokeColor = NSColor.systemRed.cgColor
        }
    }

    static func screenRect(_ rect: Rect, viewport: Viewport) -> NSRect {
        NSRect(x: rect.x * viewport.scale + viewport.x, y: rect.y * viewport.scale + viewport.y,
               width: rect.width * viewport.scale, height: rect.height * viewport.scale)
    }

    static func screenPoint(_ handle: ResizeHandle, of rect: Rect, viewport: Viewport) -> NSPoint {
        let r = screenRect(rect, viewport: viewport)
        return NSPoint(x: r.minX + r.width * handle.anchor.x, y: r.minY + r.height * handle.anchor.y)
    }

    /// The screen rectangle of a top-level frame's name label: above the frame's top-left corner, no wider than the frame.
    static func labelRect(for node: DesignNode, viewport: Viewport) -> NSRect {
        let frame = screenRect(node.frame, viewport: viewport)
        let textWidth = labelWidth(node.name) + 2
        return NSRect(x: frame.minX, y: frame.minY - labelHeight - 4, width: max(16, min(textWidth, frame.width)), height: labelHeight)
    }

    /// Name widths are measured once per name: hit testing and rendering ask for every top-level frame's label on each pointer event.
    private static var labelWidths: [String: CGFloat] = [:]

    private static func labelWidth(_ name: String) -> CGFloat {
        if let width = labelWidths[name] { return width }
        let width = (name as NSString).size(withAttributes: [.font: labelFont]).width
        if labelWidths.count >= 5000 { labelWidths.removeAll(keepingCapacity: true) }
        labelWidths[name] = width
        return width
    }

    func render(viewport: Viewport, index: DesignIndex, selection: Set<String>, hover: String?,
                marquee: Rect?, guides: [Guide], handlesFor handleTarget: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func outline(_ ids: [String]) -> CGPath {
            let path = CGMutablePath()
            for id in ids { if let rect = index.worldRect(id) { path.addRect(Self.screenRect(rect, viewport: viewport)) } }
            return path
        }
        hoverLayer.path = outline(hover.flatMap { selection.contains($0) ? nil : [$0] } ?? [])
        selectionLayer.path = outline(Array(selection))
        let handles = CGMutablePath()
        if let id = handleTarget, let rect = index.worldRect(id) {
            let size = Self.handleSize
            for handle in ResizeHandle.allCases {
                let point = Self.screenPoint(handle, of: rect, viewport: viewport)
                handles.addRect(CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            }
        }
        handleLayer.path = handles
        marqueeLayer.path = marquee.map { CGPath(rect: NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height), transform: nil) }
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
        renderLabels(document: index.document, viewport: viewport, selection: selection)
        CATransaction.commit()
    }

    private func renderLabels(document: DesignDocument, viewport: Viewport, selection: Set<String>) {
        let frames = document.nodes.filter { $0.type == .frame && $0.visible }
        var seen = Set<String>()
        let scale = window?.backingScaleFactor ?? 2
        for node in frames {
            seen.insert(node.id)
            let label = labels[node.id] ?? {
                let layer = CATextLayer()
                layer.actions = DesignRenderer.noActions
                layer.font = Self.labelFont
                layer.fontSize = Self.labelFont.pointSize
                layer.truncationMode = .end
                layer.anchorPoint = .zero
                labelHost.addSublayer(layer)
                labels[node.id] = layer
                return layer
            }()
            label.contentsScale = scale
            if label.string as? String != node.name { label.string = node.name }
            label.foregroundColor = selection.contains(node.id) ? accent : secondary
            let rect = Self.labelRect(for: node, viewport: viewport)
            label.position = rect.origin
            label.bounds = CGRect(origin: .zero, size: rect.size)
        }
        for (id, layer) in labels where !seen.contains(id) {
            layer.removeFromSuperlayer()
            labels[id] = nil
        }
    }
}
