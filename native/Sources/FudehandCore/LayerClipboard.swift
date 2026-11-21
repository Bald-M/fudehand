import Foundation

/// Layers copied with Copy or Cut, and where Paste and Duplicate put them (see "Copy and Paste" in `docs/macos.md`).
/// The copied layers keep everything but their ids: children, image data, effects, and prototype settings.
public struct LayerClipboard: Equatable {
    /// The pasteboard type that holds `data()`; only Fudehand reads it.
    public static let pasteboardType = "app.fudehand.layers"
    /// How far each paste beside the original moves down and right, in points.
    public static let pasteOffset = 10.0

    /// The outermost copied layers in stacking order, with `x` and `y` in canvas coordinates.
    public private(set) var nodes: [DesignNode]
    /// The ids the copied layers had in the document they came from.
    public private(set) var sources: [String]
    /// The parent the copied layers shared: `.some(nil)` for the top level, nil when they had different parents.
    public private(set) var parent: String??
    /// That parent's position on the canvas when the layers were copied; zero for the top level or different parents.
    public private(set) var origin: Point

    /// The outermost of `ids` (a layer selected with its ancestor goes with the ancestor). Throws when no id is given or one is missing.
    public init(copying ids: Set<String>, from document: DesignDocument) throws {
        guard !ids.isEmpty else { throw DesignError("No layers to copy") }
        let existing = document.allIDs()
        if let missing = ids.sorted().first(where: { !existing.contains($0) }) { throw DesignError("Layer not found: \(missing)") }
        var roots: [String] = []
        document.forEach { node in
            if ids.contains(node.id), !document.ancestry(of: node.id).dropLast().contains(where: ids.contains) { roots.append(node.id) }
        }
        let parents = Set(roots.map { document.parentID(of: $0)! })
        sources = roots
        let shared: String?? = parents.count == 1 ? .some(parents.first!) : .none
        parent = shared
        origin = shared.flatMap { $0 }.flatMap { document.worldRect($0) }.map { Point(x: $0.x, y: $0.y) } ?? Point(x: 0, y: 0)
        nodes = roots.map { id in
            var node = document.node(id)!
            let world = document.worldRect(id)!
            node.x = world.x
            node.y = world.y
            return node
        }
    }

    public init(data: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["format"] as? String == Self.pasteboardType,
              let nodes = object["nodes"] as? [Any], let sources = object["sources"] as? [String],
              let originX = object["originX"] as? Double, let originY = object["originY"] as? Double else {
            throw DesignError("Not Fudehand layers")
        }
        self.nodes = try nodes.map(DesignJSON.node(from:))
        self.sources = sources
        switch object["parent"] {
        case nil: parent = nil
        case is NSNull: parent = .some(nil)
        case let id as String: parent = .some(id)
        default: throw DesignError("Not Fudehand layers")
        }
        origin = Point(x: originX, y: originY)
    }

    /// The JSON written to the pasteboard, image data included.
    public func data() throws -> Data {
        var object: [String: Any] = ["format": Self.pasteboardType, "sources": sources, "originX": origin.x, "originY": origin.y,
                                     "nodes": nodes.map { DesignJSON.object($0, includeImageData: true) }]
        if let parent { object["parent"] = parent ?? NSNull() }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The copied layers' bounding box on the canvas.
    public var bounds: Rect { Rect.union(nodes.map(\.frame))! }

    /// The frame Paste puts the layers into: the one selected layer when it is a frame, unless it is in `excluding` (the copied
    /// layers and the copies already pasted from this clipboard, so pasting a copied frame again puts it beside, not inside).
    public static func target(selection: Set<String>, in document: DesignDocument, excluding: Set<String>) -> String? {
        guard selection.count == 1, let id = selection.first, !excluding.contains(id), document.node(id)?.type == .frame else { return nil }
        return id
    }

    /// Inserts a copy of the layers with new ids and returns the ids of the outermost copies.
    ///
    /// - Into `frame` when given: at the same offset from it that the layers had from their parent, when that fits inside it,
    ///   otherwise centered in it.
    /// - Otherwise into the parent the layers came from when this document still has it (the top level otherwise), moved
    ///   `step` × `pasteOffset` down and right, just above the topmost of `related` and the copied layers in that parent.
    ///   When that place does not overlap `visible` (nil counts as visible), the copies go to the top level, centered in `visible`.
    ///
    /// Toggle-visibility targets inside the copy are pointed at the copied layers; references to layers this document lacks are dropped.
    public func paste(into document: inout DesignDocument, frame: String?, visible: Rect?, step: Int, related: Set<String>) throws -> [String] {
        let box = bounds
        var target: String?
        var delta: Point
        var index: Int?
        if let frame {
            guard let rect = document.worldRect(frame), document.node(frame)?.type.hasChildren == true else {
                throw DesignError("Layer not found: \(frame)")
            }
            target = frame
            let kept = parent.flatMap { $0 }.map { _ in Point(x: rect.x - origin.x, y: rect.y - origin.y) }
            if let kept, rect.contains(Point(x: box.minX + kept.x, y: box.minY + kept.y)),
               rect.contains(Point(x: box.maxX + kept.x, y: box.maxY + kept.y)) {
                delta = kept
            } else {
                delta = Point(x: rect.midX - box.midX, y: rect.midY - box.midY)
            }
        } else {
            let home = parent.flatMap { $0 }.flatMap { id in document.node(id)?.type.hasChildren == true ? id : nil }
            let shift = home.flatMap(document.worldRect).map { Point(x: $0.x - origin.x, y: $0.y - origin.y) } ?? Point(x: 0, y: 0)
            let offset = Double(step) * Self.pasteOffset
            delta = Point(x: shift.x + offset, y: shift.y + offset)
            if let visible, !box.offsetBy(delta).intersects(visible) {
                delta = Point(x: visible.midX - box.midX, y: visible.midY - box.midY)
            } else {
                target = home
                let siblings = home.flatMap { document.node($0)?.children } ?? document.nodes
                let near = related.union(sources)
                index = siblings.lastIndex { near.contains($0.id) }.map { $0 + 1 }
            }
        }
        let parentOrigin = target.flatMap(document.worldRect) ?? Rect(x: 0, y: 0, width: 0, height: 0)

        let copies = renamedCopies(existing: document.allIDs())
        var roots: [String] = []
        for (offset, node) in nodes.enumerated() {
            var next = copies.nodes[offset]
            next.x = node.x + delta.x - parentOrigin.x
            next.y = node.y + delta.y - parentOrigin.y
            try document.insert(next, parent: target, index: index.map { $0 + offset })
            roots.append(next.id)
        }
        try dropUnreachableReferences(of: copies.ids, in: &document)
        return roots
    }

    /// Duplicate: inserts a copy of each copied layer just above its original, in the original's parent, moved `pasteOffset` down
    /// and right, and returns the copies' ids. The originals must still be in `document`.
    public func duplicate(in document: inout DesignDocument) throws -> [String] {
        let copies = renamedCopies(existing: document.allIDs())
        for (source, copy) in zip(sources, copies.nodes) {
            guard let path = document.indexPath(of: source) else { throw DesignError("Layer not found: \(source)") }
            var next = copy
            let original = document.node(source)!
            next.x = original.x + Self.pasteOffset
            next.y = original.y + Self.pasteOffset
            try document.insert(next, parent: document.parentID(of: source)!, index: path.last! + 1)
        }
        try dropUnreachableReferences(of: copies.ids, in: &document)
        return copies.nodes.map(\.id)
    }

    /// The copied layers with new ids that `existing` lacks, toggle-visibility targets inside the copy pointed at the copies,
    /// and every new id.
    private func renamedCopies(existing: Set<String>) -> (nodes: [DesignNode], ids: [String]) {
        var existing = existing
        var renamed: [String: String] = [:]
        DesignDocument(nodes: nodes).forEach { node in
            let id = DesignDocument.newID(existing: existing)
            existing.insert(id)
            renamed[node.id] = id
        }
        func copy(_ node: DesignNode) -> DesignNode {
            var next = node
            next.id = renamed[node.id]!
            if case .toggleVisibility(let targets) = node.interaction { next.interaction = .toggleVisibility(targets: targets.map { renamed[$0] ?? $0 }) }
            next.children = node.children.map(copy)
            return next
        }
        return (nodes.map(copy), Array(renamed.values))
    }

    /// Removes interactions of the copies that point at frames or layers `document` lacks.
    private func dropUnreachableReferences(of ids: [String], in document: inout DesignDocument) throws {
        let all = document.allIDs(), pasted = document
        for id in ids {
            try document.update(id) { node in
                switch node.interaction {
                case .navigate(let destination, _), .openOverlay(let destination, _, _):
                    if Prototype.frame(destination, in: pasted) == nil { node.interaction = nil }
                case .toggleVisibility(let targets):
                    let kept = targets.filter(all.contains)
                    node.interaction = kept.isEmpty ? nil : .toggleVisibility(targets: kept)
                case .back, .closeOverlay, nil: break
                }
            }
        }
    }
}
