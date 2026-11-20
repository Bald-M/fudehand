import AppKit
import FudehandCore

/// Screen-space decorations drawn above the layers: hover, selection box, resize handles, top-level frame names, marquee selection,
/// snapping guides, and annotation markers. Never receives pointer input; the canvas hit-tests markers with `markerRect`.
final class CanvasOverlay: NSView {
    override var isFlipped: Bool { true }
    private let hoverLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private let guideLayer = CAShapeLayer()
    private let labelHost = CALayer()
    private var labels: [String: CATextLayer] = [:]
    private let markerHost = CALayer()
    private var markers: [String: AnnotationMarkerLayer] = [:]
    static let markerSize = 24.0
    /// The id the marker of an annotation being written, not yet added, is drawn under.
    static let draftMarker = "#draft"
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
        markerHost.actions = DesignRenderer.noActions
        layer?.addSublayer(markerHost)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Screen-space bounds of the drawn selection outlines; `.null` when nothing is selected.
    var selectionBounds: CGRect { selectionLayer.path?.boundingBoxOfPath ?? .null }
    var labelTexts: [String: String] { labels.compactMapValues { $0.string as? String } }
    /// The drawn markers' counts by annotation id, and which one is expanded; for tests.
    var markerCounts: [String: String] { markers.compactMapValues { $0.count.string as? String } }
    var expandedMarker: String? { markers.first { $0.value.expanded }?.key }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [hoverLayer, selectionLayer, handleLayer, marqueeLayer, guideLayer, labelHost, markerHost] { shape.frame = bounds }
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markers.values.forEach { $0.updateColors(effectiveAppearance) }
        CATransaction.commit()
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

    /// The screen rectangle of an annotation marker: a speech bubble whose pointed bottom-left corner is the anchor.
    static func markerRect(_ anchor: Point, viewport: Viewport) -> NSRect {
        NSRect(x: anchor.x * viewport.scale + viewport.x, y: anchor.y * viewport.scale + viewport.y - markerSize,
               width: markerSize, height: markerSize)
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
                marquee: Rect?, guides: [Guide], handlesFor handleTarget: String?,
                markers: [(id: String, count: Int, anchor: Point)] = [], expanded: String? = nil) {
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
        renderMarkers(markers, expanded: expanded, viewport: viewport)
        CATransaction.commit()
    }

    private func renderMarkers(_ items: [(id: String, count: Int, anchor: Point)], expanded: String?, viewport: Viewport) {
        let scale = window?.backingScaleFactor ?? 2
        var seen = Set<String>()
        for item in items {
            seen.insert(item.id)
            let marker = markers[item.id] ?? {
                let layer = AnnotationMarkerLayer()
                markerHost.addSublayer(layer)
                markers[item.id] = layer
                return layer
            }()
            marker.frame = Self.markerRect(item.anchor, viewport: viewport)
            marker.show(count: item.count, expanded: item.id == expanded, contentsScale: scale, appearance: effectiveAppearance)
            // Later annotations are drawn on top, matching the order the canvas hit-tests them in.
            markerHost.addSublayer(marker)
        }
        for (id, layer) in markers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            markers[id] = nil
        }
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

/// One annotation marker: a round speech bubble pointing at its anchor, showing how many messages its thread holds.
final class AnnotationMarkerLayer: CALayer {
    let count = CATextLayer()
    private(set) var expanded = false

    override init() {
        super.init()
        cornerRadius = CanvasOverlay.markerSize / 2
        // The overlay is flipped, so the layer's maximum-y corner is drawn at the bottom: that one stays sharp.
        maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        borderWidth = 2
        shadowOpacity = 0.25
        shadowRadius = 3
        shadowOffset = CGSize(width: 0, height: 1)
        count.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        count.fontSize = 11
        count.alignmentMode = .center
        addSublayer(count)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(count value: Int, expanded: Bool, contentsScale scale: CGFloat, appearance: NSAppearance) {
        let text = value > 99 ? "99+" : String(value)
        if count.string as? String != text { count.string = text }
        count.contentsScale = scale
        count.frame = CGRect(x: 0, y: (bounds.height - 14) / 2, width: bounds.width, height: 14)
        if self.expanded != expanded || backgroundColor == nil {
            self.expanded = expanded
            updateColors(appearance)
        }
    }

    /// Callers disable implicit animations: the overlay draws inside a transaction without actions.
    func updateColors(_ appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            backgroundColor = (expanded ? NSColor.controlAccentColor : NSColor.systemYellow).cgColor
            count.foregroundColor = (expanded ? NSColor.white : NSColor.black).cgColor
            borderColor = NSColor.white.cgColor
        }
    }
}
