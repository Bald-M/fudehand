import Foundation

/// A layer the canvas exposes to assistive technologies such as VoiceOver (issue #174). The canvas draws layers with
/// Core Animation, which VoiceOver cannot see, so it lists these as accessibility children for browsing and locating;
/// editing still goes through the panels.
public struct CanvasAccessibilityItem: Equatable {
    public let id: String
    public let name: String
    public let type: NodeType
    /// The absolute rectangle in canvas coordinates.
    public let rect: Rect
    public let selected: Bool

    /// The rectangle in the canvas view's (flipped) coordinates for `viewport`.
    public func viewRect(_ viewport: Viewport) -> Rect {
        Rect(x: rect.x * viewport.scale + viewport.x, y: rect.y * viewport.scale + viewport.y,
             width: rect.width * viewport.scale, height: rect.height * viewport.scale)
    }
}

public enum CanvasAccessibility {
    /// The top-level layers in document order, followed by any selected nested layers in tree order.
    public static func items(index: DesignIndex, selection: Set<String>) -> [CanvasAccessibilityItem] {
        var items: [CanvasAccessibilityItem] = []
        func add(_ node: DesignNode) {
            guard let rect = index.worldRect(node.id) else { return }
            items.append(CanvasAccessibilityItem(id: node.id, name: node.name, type: node.type, rect: rect,
                                                 selected: selection.contains(node.id)))
        }
        index.document.nodes.forEach(add)
        guard !selection.isEmpty else { return items }
        func visit(_ nodes: [DesignNode]) {
            for node in nodes {
                if selection.contains(node.id) { add(node) }
                visit(node.children)
            }
        }
        index.document.nodes.forEach { visit($0.children) }
        return items
    }
}
