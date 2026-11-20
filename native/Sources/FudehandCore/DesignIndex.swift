import Foundation

/// A lookup table over one document: every layer's place in the tree and its absolute rectangle, built in a single traversal.
/// The document's own lookups (`indexPath`, `worldRect`, …) search the whole tree on every call. The canvas and the store ask
/// about many layers on every pointer event, so they build this once per document change and read from it instead (#52).
public struct DesignIndex {
    /// A frame whose layout guides the canvas draws: its absolute rectangle, the part of it left visible by clipping ancestors, and
    /// its visible guides.
    public struct GuideFrame: Equatable {
        public var id: String
        public var rect: Rect
        public var clip: Rect
        public var guides: [LayoutGuide]
    }

    private struct Entry {
        var parent: String?
        /// The position among the parent's children.
        var position: Int
        var rect: Rect
    }

    public let document: DesignDocument
    private let entries: [String: Entry]
    /// Visible frames (with every ancestor visible) that have at least one visible layout guide, in depth-first order.
    public let guideFrames: [GuideFrame]

    public init(_ document: DesignDocument = DesignDocument()) {
        self.document = document
        var entries: [String: Entry] = [:]
        var guideFrames: [GuideFrame] = []
        /// `clip` is nil while no ancestor clips; `shown` is false below a hidden layer.
        func visit(_ nodes: [DesignNode], parent: String?, x: Double, y: Double, clip: Rect?, shown: Bool) {
            for (position, node) in nodes.enumerated() {
                let rect = Rect(x: x + node.x, y: y + node.y, width: node.width, height: node.height)
                entries[node.id] = Entry(parent: parent, position: position, rect: rect)
                let visible = shown && node.visible
                if visible, node.type == .frame {
                    let guides = node.layoutGuides.filter(\.visible)
                    if !guides.isEmpty { guideFrames.append(GuideFrame(id: node.id, rect: rect, clip: clip.map { $0.clamped(rect) } ?? rect, guides: guides)) }
                }
                let childClip = node.type == .frame && node.clipsContent ? (clip.map { $0.clamped(rect) } ?? rect) : clip
                visit(node.children, parent: node.id, x: rect.x, y: rect.y, clip: childClip, shown: visible)
            }
        }
        visit(document.nodes, parent: nil, x: 0, y: 0, clip: nil, shown: true)
        self.entries = entries
        self.guideFrames = guideFrames
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
