import Foundation

/// A lookup table over one document: every layer's place in the tree and its absolute rectangle, built in a single traversal.
/// The document's own lookups (`indexPath`, `worldRect`, …) search the whole tree on every call. The canvas and the store ask
/// about many layers on every pointer event, so they build this once per document change and read from it instead (#52).
public struct DesignIndex {
    private struct Entry {
        var parent: String?
        /// The position among the parent's children.
        var position: Int
        var rect: Rect
    }

    public let document: DesignDocument
    private let entries: [String: Entry]

    public init(_ document: DesignDocument = DesignDocument()) {
        self.document = document
        var entries: [String: Entry] = [:]
        func visit(_ nodes: [DesignNode], parent: String?, x: Double, y: Double) {
            for (position, node) in nodes.enumerated() {
                let rect = Rect(x: x + node.x, y: y + node.y, width: node.width, height: node.height)
                entries[node.id] = Entry(parent: parent, position: position, rect: rect)
                visit(node.children, parent: node.id, x: rect.x, y: rect.y)
            }
        }
        visit(document.nodes, parent: nil, x: 0, y: 0)
        self.entries = entries
    }

    public func contains(_ id: String) -> Bool { entries[id] != nil }

    /// The absolute rectangle of a node on the canvas.
    public func worldRect(_ id: String) -> Rect? { entries[id]?.rect }

    /// An outer nil means the node was not found; an inner nil means a top-level node.
    public func parentID(of id: String) -> String?? { entries[id].map(\.parent) }

    /// The list of ids from the top level to this node (inclusive).
    public func ancestry(of id: String) -> [String] {
        var ids: [String] = []
        var next: String? = entries[id] == nil ? nil : id
        while let current = next {
            ids.append(current)
            next = entries[current]?.parent
        }
        return ids.reversed()
    }

    /// The index path of a node in the tree.
    public func indexPath(of id: String) -> [Int]? {
        guard var entry = entries[id] else { return nil }
        var path = [entry.position]
        while let parent = entry.parent, let above = entries[parent] {
            path.append(above.position)
            entry = above
        }
        return path.reversed()
    }

    public func node(_ id: String) -> DesignNode? { indexPath(of: id).map { document[$0] } }
}
