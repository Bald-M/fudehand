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
            // Copied out of an instance: nested instances in it stay instances of their own main component.
            if let root = document.ancestry(of: id).dropLast().lazy.compactMap(document.node).first(where: { $0.instance != nil }),
               let component = root.instance {
                ComponentSync.unlink(&node, outOf: component, in: document)
            }
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

    /// The frame Paste puts the layers into: the one selected layer when it is a frame that takes new layers (not an instance or
    /// inside one), unless it is in `excluding` (the copied layers and the copies already pasted from this clipboard, so pasting
    /// a copied frame again puts it beside, not inside).
    public static func target(selection: Set<String>, in document: DesignDocument, excluding: Set<String>) -> String? {
        guard selection.count == 1, let id = selection.first, !excluding.contains(id), document.acceptsInsertedLayers(id) else { return nil }
        return id
    }

    /// Inserts a copy of the layers with new ids and returns the ids of the outermost copies.
    ///
    /// - Into `frame` when given: at the same offset from it that the layers had from their parent, when that fits inside it,
    ///   otherwise centered in it.
    /// - Otherwise into the parent the layers came from when this document still has it (the top level otherwise), moved
    ///   `step` × `pasteOffset` down and right, just above the topmost of `related` and the copied layers in that parent. When
    ///   that parent is an instance or inside one (layers copied out of an instance), they go into the parent of the outermost
    ///   instance root instead, just above it (or above `related`).
    ///   When that place does not overlap `visible` (nil counts as visible), the copies go to the top level, centered in `visible`.
    ///
    /// Toggle-visibility targets inside the copy are pointed at the copied layers; references to layers this document lacks are dropped.
    public func paste(into document: inout DesignDocument, frame: String?, visible: Rect?, step: Int, related: Set<String>) throws -> [String] {
        if let frame, document.node(frame)?.componentSet != nil { return try pasteVariants(into: &document, set: frame) }
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
                // Nothing can be inserted inside an instance, so copies of its layers go beside its outermost root; copies of
                // variants go beside their component set.
                let instance = home.flatMap { document.ancestry(of: $0).first { document.node($0)?.instance != nil } }
                let blocked = instance ?? home.flatMap { document.node($0)?.componentSet != nil ? $0 : nil }
                target = blocked.map { document.parentID(of: $0) ?? nil } ?? home
                let siblings = target.flatMap { document.node($0)?.children } ?? document.nodes
                let near = related.union(sources).union(blocked.map { [$0] } ?? [])
                index = siblings.lastIndex { near.contains($0.id) }.map { $0 + 1 }
            }
        }
        let parentOrigin = target.flatMap(document.worldRect) ?? Rect(x: 0, y: 0, width: 0, height: 0)

        let copies = preparedCopies(of: nodes, for: document)
        var roots: [String] = []
        for (offset, node) in nodes.enumerated() {
            var next = copies[offset]
            next.x = node.x + delta.x - parentOrigin.x
            next.y = node.y + delta.y - parentOrigin.y
            try document.insert(next, parent: target, index: index.map { $0 + offset })
            roots.append(next.id)
        }
        ComponentSync.repair(&document, within: Set(roots))
        try dropUnreachableReferences(of: copies, in: &document)
        return roots
    }

    /// Pastes the copied layers into component set `set` as new variants (see `ComponentVariants.insertVariant`); refused unless
    /// every copied layer is a main component.
    private func pasteVariants(into document: inout DesignDocument, set: String) throws -> [String] {
        guard nodes.allSatisfy(\.component) else { throw DesignDocument.componentSetRefusal(set) }
        var existing = document.allIDs()
        let copies = ComponentVariants.freshCopies(nodes, existing: &existing)
        for (node, copy) in zip(nodes, copies) {
            _ = try ComponentVariants.insertVariant(copy, values: node.variant ?? [:], fallback: node.name, into: set, after: nil,
                                                    in: &document)
        }
        ComponentSync.repair(&document, within: Set(copies.map(\.id)))
        try dropUnreachableReferences(of: copies, in: &document)
        return copies.map(\.id)
    }

    /// Duplicate: inserts a copy of each copied layer just above its original, in the original's parent, moved `pasteOffset` down
    /// and right, and returns the copies' ids. A copied variant becomes a new variant of its set instead, as Add Variant makes
    /// it. The originals must still be in `document`.
    public func duplicate(in document: inout DesignDocument) throws -> [String] {
        let variants = sources.indices.filter { ComponentVariants.set(of: sources[$0], in: document) != nil }
        let others = sources.indices.filter { !variants.contains($0) }
        let copies = preparedCopies(of: others.map { nodes[$0] }, for: document)
        var result = Array(repeating: "", count: sources.count)
        for (offset, copy) in zip(others, copies) {
            let source = sources[offset]
            guard let path = document.indexPath(of: source) else { throw DesignError("Layer not found: \(source)") }
            result[offset] = copy.id
            var next = copy
            let original = document.node(source)!
            next.x = original.x + Self.pasteOffset
            next.y = original.y + Self.pasteOffset
            try document.insert(next, parent: document.parentID(of: source)!, index: path.last! + 1)
        }
        // After the other copies, so that the ids Add Variant picks cannot be taken by them.
        for offset in variants { result[offset] = try ComponentVariants.addVariant(from: sources[offset], in: &document) }
        ComponentSync.repair(&document, within: Set(result))
        try dropUnreachableReferences(of: copies, in: &document)
        return result
    }

    /// The copied layers as they go into `document` (see "Creating" in the components spec), with new ids:
    /// - A copied main component whose id is a main component in `document` becomes an instance of it.
    /// - One whose id (and its layers' ids) `document` lacks while instances there still name it (Cut, then Paste) keeps its ids.
    /// - Any other stays a main component with a new id, and copied instances of it are linked to the copy.
    /// Layers copied out of an instance (below its root) lose their link; instances that cannot be linked are detached by the
    /// repair after inserting.
    private func preparedCopies(of nodes: [DesignNode], for document: DesignDocument) -> [DesignNode] {
        var referenced: Set<String> = []
        document.forEach { if let id = $0.instance { referenced.insert(id) } }
        let existing = document.allIDs()
        var asInstance: Set<String> = []
        var kept: Set<String> = []
        /// Main components copied under a new id: instances of them copied with them follow the copy.
        var movedMains: Set<String> = []
        DesignDocument(nodes: nodes).forEach { node in
            guard node.component else { return }
            let ids = DesignDocument(nodes: [node]).allIDs()
            if document.node(node.id)?.component == true {
                asInstance.insert(node.id)
            } else if referenced.contains(node.id), ids.isDisjoint(with: existing) {
                kept.formUnion(ids)
            } else {
                movedMains.insert(node.id)
            }
        }
        var taken = existing.union(kept)
        var renamed: [String: String] = [:]
        DesignDocument(nodes: nodes).forEach { node in
            if kept.contains(node.id) { renamed[node.id] = node.id; return }
            let id = DesignDocument.newID(existing: taken)
            taken.insert(id)
            renamed[node.id] = id
        }
        /// `relink` is true inside an instance whose main component is copied with it under a new id.
        func copy(_ node: DesignNode, inInstance: Bool, relink: Bool) -> DesignNode {
            if node.component, asInstance.contains(node.id) {
                var instance = ComponentSync.makeInstance(of: document.node(node.id)!, existing: &taken)
                instance.x = node.x
                instance.y = node.y
                return instance
            }
            var next = node
            next.id = renamed[node.id]!
            if case .toggleVisibility(let targets) = node.interaction { next.interaction = .toggleVisibility(targets: targets.map { renamed[$0] ?? $0 }) }
            let isRoot = !inInstance && node.instance != nil
            let relink = relink || (isRoot && node.instance.map(movedMains.contains) == true)
            if !inInstance && !isRoot {
                next.source = nil
                next.overrides = []
            } else if relink {
                next.source = node.source.map { renamed[$0] ?? $0 }
                next.instance = node.instance.map { movedMains.contains($0) ? renamed[$0]! : $0 }
            }
            next.children = node.children.map { copy($0, inInstance: inInstance || isRoot, relink: relink) }
            if next.componentSet != nil, next.children.contains(where: { !$0.component }) {
                // Its variants became instances (copied within the same document): it is a plain frame holding them.
                next.componentSet = nil
                for index in next.children.indices { next.children[index].variant = nil }
            }
            return next
        }
        // A copied variant lands outside its set (pasting into a set goes through `pasteVariants`).
        return nodes.map { node in
            var next = copy(node, inInstance: false, relink: false)
            next.variant = nil
            return next
        }
    }

    /// Removes interactions of the copies (and their layers) that point at frames or layers `document` lacks.
    private func dropUnreachableReferences(of copies: [DesignNode], in document: inout DesignDocument) throws {
        let all = document.allIDs(), pasted = document
        for id in DesignDocument(nodes: copies).allIDs() where all.contains(id) {
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

extension DesignDocument {
    /// Whether `id` is a frame that inserted or pasted layers can go into: a frame that is not an instance and not inside one
    /// (a main component is fine), since an instance's structure only changes through its main component, and not a component
    /// set, which takes only variants.
    public func acceptsInsertedLayers(_ id: String) -> Bool {
        let chain = ancestry(of: id).compactMap(node)
        return chain.last?.type == .frame && chain.last?.componentSet == nil && !chain.contains { $0.instance != nil }
    }
}
