import Foundation

/// Which layer a click on the canvas selects (Figma-style rules), with no AppKit dependency.
public enum DesignHitTest {
    /// The id path, from the top level to the deepest level, of the topmost visible, unlocked layer under a point in canvas coordinates. Locked or hidden layers and their children are skipped;
    /// children outside a frame that clips its content cannot be hit.
    public static func path(at point: Point, in document: DesignDocument) -> [String] {
        func search(_ nodes: [DesignNode], origin: Point) -> [String]? {
            for node in nodes.reversed() where node.visible && !node.locked {
                let rect = Rect(x: origin.x + node.x, y: origin.y + node.y, width: node.width, height: node.height)
                let inside = point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
                let clips = node.type == .frame && node.clipsContent
                if !clips || inside, let deeper = search(node.children, origin: Point(x: rect.x, y: rect.y)) {
                    return [node.id] + deeper
                }
                // A group has no content of its own and can only be hit through its children.
                if inside, node.type != .group { return [node.id] }
            }
            return nil
        }
        return search(document.nodes, origin: Point(x: 0, y: 0)) ?? []
    }

    /// Decides which level of the hit path to select given the current selection: inside a top-level frame its children are selected directly; siblings of a selected layer can be hit directly;
    /// `deep` (⌘-click) selects the deepest level.
    public static func selectable(path: [String], selection: Set<String>, document: DesignDocument, deep: Bool) -> String? {
        guard !path.isEmpty else { return nil }
        if deep { return path.last }
        var depth = 0
        if path.count > 1, document.node(path[0])?.type == .frame { depth = 1 }
        for id in selection {
            let ancestry = document.ancestry(of: id)
            let level = ancestry.count - 1
            if level > depth, path.count > level, Array(path.prefix(level)) == Array(ancestry.prefix(level)) { depth = level }
        }
        return path[min(depth, path.count - 1)]
    }

    /// Double-clicking a selected layer: selects its next-level child under the pointer; returns nil when there is none.
    public static func enter(_ id: String, at point: Point, in document: DesignDocument) -> String? {
        let hit = path(at: point, in: document)
        guard let index = hit.firstIndex(of: id), index + 1 < hit.count else { return nil }
        return hit[index + 1]
    }
}
