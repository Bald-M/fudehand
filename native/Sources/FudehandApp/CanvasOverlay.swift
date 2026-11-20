import AppKit
import FudehandCore

/// Screen-space decorations drawn above the layers: frame layout guides, hover, selection box, resize handles, top-level frame
/// names, marquee selection, and snapping guides. Never receives pointer input, and never appears in snapshots or playback.
final class CanvasOverlay: NSView {
    override var isFlipped: Bool { true }
    private let hoverLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let labelHost = CALayer()
    private let layoutGuideHost = CALayer()
    /// One shape per drawn layout guide, reused across renders; the first `layoutGuideCount` are in use.
    private var layoutGuideLayers: [CAShapeLayer] = []
    private var layoutGuideCount = 0
    /// A grid whose lines would sit closer than this many screen points is not drawn, so zooming out does not fill the frame.
    static let minimumGridSpacing = 4.0
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
        layoutGuideHost.actions = DesignRenderer.noActions
        layer?.insertSublayer(layoutGuideHost, at: 0)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Screen-space bounds of the drawn selection outlines; `.null` when nothing is selected.
    var selectionBounds: CGRect { selectionLayer.path?.boundingBoxOfPath ?? .null }
    var labelTexts: [String: String] { labels.compactMapValues { $0.string as? String } }
    /// The screen-space paths of the layout guides drawn now, in drawing order.
    var layoutGuidePaths: [CGPath] { layoutGuideLayers.prefix(layoutGuideCount).compactMap(\.path) }
    /// The line widths of the grids drawn now.
    var layoutGuideLineWidths: [CGFloat] { layoutGuideLayers.prefix(layoutGuideCount).filter { $0.strokeColor != nil }.map(\.lineWidth) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [hoverLayer, selectionLayer, handleLayer, marqueeLayer, guideLayer, labelHost, layoutGuideHost] { shape.frame = bounds }
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
        renderLayoutGuides(index.guideFrames, viewport: viewport)
        renderLabels(document: index.document, viewport: viewport, selection: selection)
        CATransaction.commit()
    }

    private func renderLayoutGuides(_ frames: [DesignIndex.GuideFrame], viewport: Viewport) {
        layoutGuideCount = 0
        for frame in frames {
            let clip = frame.clip
            guard clip.width > 0, clip.height > 0 else { continue }
            for guide in frame.guides {
                let path = CGMutablePath()
                switch guide.type {
                case .grid:
                    guard guide.size * viewport.scale >= Self.minimumGridSpacing else { continue }
                    for offset in guide.gridLines(length: frame.rect.width) where (clip.minX...clip.maxX).contains(frame.rect.x + offset) {
                        let x = (frame.rect.x + offset) * viewport.scale + viewport.x
                        path.move(to: CGPoint(x: x, y: clip.minY * viewport.scale + viewport.y))
                        path.addLine(to: CGPoint(x: x, y: clip.maxY * viewport.scale + viewport.y))
                    }
                    for offset in guide.gridLines(length: frame.rect.height) where (clip.minY...clip.maxY).contains(frame.rect.y + offset) {
                        let y = (frame.rect.y + offset) * viewport.scale + viewport.y
                        path.move(to: CGPoint(x: clip.minX * viewport.scale + viewport.x, y: y))
                        path.addLine(to: CGPoint(x: clip.maxX * viewport.scale + viewport.x, y: y))
                    }
                case .columns, .rows:
                    for band in guide.rects(in: frame.rect) {
                        let visible = band.clamped(clip)
                        if visible.width > 0, visible.height > 0 { path.addRect(Self.screenRect(visible, viewport: viewport)) }
                    }
                }
                guard !path.isEmpty else { continue }
                let shape = nextLayoutGuideLayer()
                let color = CGColor(srgbRed: guide.color.r, green: guide.color.g, blue: guide.color.b, alpha: guide.color.a)
                shape.path = path
                // Grid lines are stroked 1 point wide at every zoom; columns and rows are filled.
                shape.strokeColor = guide.type == .grid ? color : nil
                shape.fillColor = guide.type == .grid ? nil : color
                shape.lineWidth = 1
            }
        }
        for (position, shape) in layoutGuideLayers.enumerated() { shape.isHidden = position >= layoutGuideCount }
    }

    private func nextLayoutGuideLayer() -> CAShapeLayer {
        defer { layoutGuideCount += 1 }
        if layoutGuideCount < layoutGuideLayers.count { return layoutGuideLayers[layoutGuideCount] }
        let shape = CAShapeLayer()
        shape.actions = DesignRenderer.noActions
        shape.frame = layoutGuideHost.bounds
        layoutGuideHost.addSublayer(shape)
        layoutGuideLayers.append(shape)
        return shape
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
