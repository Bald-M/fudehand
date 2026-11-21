import Foundation

// MARK: Tree operations

extension DesignDocument {
    /// The index path of a node in the tree.
    public func indexPath(of id: String) -> [Int]? {
        func search(_ nodes: [DesignNode], _ prefix: [Int]) -> [Int]? {
            for (index, node) in nodes.enumerated() {
                if node.id == id { return prefix + [index] }
                if let found = search(node.children, prefix + [index]) { return found }
            }
            return nil
        }
        return search(nodes, [])
    }

    public func node(_ id: String) -> DesignNode? { indexPath(of: id).map { self[$0] } }

    subscript(path: [Int]) -> DesignNode {
        get {
            var node = nodes[path[0]]
            for index in path.dropFirst() { node = node.children[index] }
            return node
        }
        set {
            func assign(_ list: inout [DesignNode], _ rest: ArraySlice<Int>) {
                let index = rest.first!
                if rest.count == 1 { list[index] = newValue } else { assign(&list[index].children, rest.dropFirst()) }
            }
            assign(&nodes, path[...])
        }
    }

    /// An outer nil means the node was not found; an inner nil means a top-level node.
    public func parentID(of id: String) -> String?? {
        guard let path = indexPath(of: id) else { return nil }
        return .some(path.count == 1 ? nil : self[Array(path.dropLast())].id)
    }

    /// The list of ids from the top level to this node (inclusive).
    public func ancestry(of id: String) -> [String] {
        guard let path = indexPath(of: id) else { return [] }
        return (1...path.count).map { self[Array(path.prefix($0))].id }
    }

    /// The absolute rectangle of a node on the canvas.
    public func worldRect(_ id: String) -> Rect? {
        guard let path = indexPath(of: id) else { return nil }
        var x = 0.0, y = 0.0
        for depth in 1...path.count {
            let node = self[Array(path.prefix(depth))]
            x += node.x; y += node.y
        }
        let node = self[path]
        return Rect(x: x, y: y, width: node.width, height: node.height)
    }

    public func allIDs() -> Set<String> {
        var ids = Set<String>()
        forEach { ids.insert($0.id) }
        return ids
    }

    private func children(of parent: String?) throws -> (path: [Int]?, list: [DesignNode]) {
        guard let parent else { return (nil, nodes) }
        guard let path = indexPath(of: parent) else { throw DesignError("Layer not found: \(parent)") }
        let node = self[path]
        guard node.type.hasChildren else { throw DesignError("Layer \(parent) cannot contain child layers") }
        return (path, node.children)
    }

    private mutating func setChildren(_ list: [DesignNode], at path: [Int]?) {
        if let path { self[path].children = list } else { nodes = list }
    }

    public mutating func insert(_ node: DesignNode, parent: String?, index: Int?) throws {
        let (path, list) = try children(of: parent)
        let existing = allIDs()
        var duplicate: String?
        DesignDocument(nodes: [node]).forEach { if duplicate == nil, existing.contains($0.id) { duplicate = $0.id } }
        if let duplicate { throw DesignError("Duplicate layer id: \(duplicate)") }
        try DesignDocument(nodes: [node]).validateUniqueIDs()
        let position = index ?? list.count
        guard (0...list.count).contains(position) else { throw DesignError("index out of range: 0–\(list.count)") }
        var next = list
        next.insert(node, at: position)
        setChildren(next, at: path)
    }

    public mutating func update(_ id: String, _ change: (inout DesignNode) throws -> Void) throws {
        guard let path = indexPath(of: id) else { throw DesignError("Layer not found: \(id)") }
        try update(at: path, change)
    }

    /// Changes the node at an index path of this document (see `DesignIndex.indexPath`) without searching the tree.
    public mutating func update(at path: [Int], _ change: (inout DesignNode) throws -> Void) rethrows {
        var node = self[path]
        try change(&node)
        self[path] = node
    }

    /// Deletes nodes and their subtrees; when any id does not exist, nothing is deleted.
    public mutating func delete(_ ids: Set<String>) throws {
        let existing = allIDs()
        if let missing = ids.sorted().first(where: { !existing.contains($0) }) { throw DesignError("Layer not found: \(missing)") }
        func prune(_ list: [DesignNode]) -> [DesignNode] {
            list.filter { !ids.contains($0.id) }.map { node in
                var copy = node
                copy.children = prune(node.children)
                return copy
            }
        }
        nodes = prune(nodes)
    }

    /// Moves to a new parent node (nil for the top level) and position, keeping the absolute position on the canvas. `index` is the position in the new parent after the node is removed.
    public mutating func move(_ id: String, parent: String?, index: Int?) throws {
        guard let path = indexPath(of: id), let world = worldRect(id) else { throw DesignError("Layer not found: \(id)") }
        if let parent, ancestry(of: parent).contains(id) { throw DesignError("Cannot move a layer into itself or its descendants") }
        var node = self[path]
        var copy = self
        try copy.delete([id])
        let origin = try parent.map { parent -> Rect in
            guard let rect = copy.worldRect(parent) else { throw DesignError("Layer not found: \(parent)") }
            return rect
        }
        node.x = world.x - (origin?.x ?? 0)
        node.y = world.y - (origin?.y ?? 0)
        try copy.insert(node, parent: parent, index: index)
        self = copy
    }

    private static let idAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func newID(existing: Set<String>) -> String {
        while true {
            let id = String((0..<8).map { _ in idAlphabet.randomElement()! })
            if !existing.contains(id) { return id }
        }
    }

    /// Fills in the missing ids of a new node in JSON form and of its children; used when the Agent creates layers.
    public static func assigningIDs(_ object: [String: Any], existing: inout Set<String>) -> [String: Any] {
        var result = object
        if result["id"] == nil || result["id"] is NSNull || (result["id"] as? String)?.isEmpty == true {
            let id = newID(existing: existing)
            result["id"] = id
            existing.insert(id)
        } else if let id = result["id"] as? String {
            existing.insert(id)
        }
        if let children = result["children"] as? [Any] {
            result["children"] = children.map { child -> Any in
                guard let child = child as? [String: Any] else { return child }
                return assigningIDs(child, existing: &existing)
            }
        }
        return result
    }
}

// MARK: Editor

/// The document and the undo history. Manual edits and Agent edits share one history, annotations included; layout runs again after
/// every edit, and annotations on layers an edit removed are dropped with it.
public struct DesignEditor {
    private struct Step {
        let name: String
        let before: DesignDocument
        let coalescing: String?
        var time = Date()
    }
    /// Edits with the same coalescing key are merged into one step only when they happen in succession within this interval.
    public static let coalescingWindow: TimeInterval = 1.5

    public private(set) var document: DesignDocument
    /// Incremented on every document change (including undo, redo, and replace).
    public private(set) var revision = 0
    private let measure: TextMeasure
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var gesture: (name: String, start: DesignDocument)?
    public static let historyLimit = 200

    public init(document: DesignDocument = DesignDocument(), measure: @escaping TextMeasure) {
        self.measure = measure
        var laidOut = document
        DesignLayout.apply(to: &laidOut.nodes, measure: measure)
        self.document = laidOut
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// One edit is one undo step; when the edit throws or changes nothing, both the document and the history are unchanged. Successive edits with the same `coalescing` are merged into one step.
    @discardableResult
    /// While a continuous gesture is in progress (for example the Agent sends an edit during a drag), the part dragged so far is first recorded as one step, and after the edit the drag continues recording from the new state.
    public mutating func perform<T>(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> T) rethrows -> T {
        let open = gesture?.name
        endGesture()
        defer { if let open { gesture = (open, document) } }
        var next = document
        let result = try change(&next)
        next.pruneAnnotations()
        DesignLayout.apply(to: &next.nodes, measure: measure, unchangedFrom: document.nodes)
        guard next != document else { return result }
        let now = Date()
        if coalescing == nil || undoStack.last?.coalescing != coalescing || !redoStack.isEmpty
            || now.timeIntervalSince(undoStack.last?.time ?? .distantPast) > Self.coalescingWindow {
            push(Step(name: name, before: document, coalescing: coalescing, time: now))
        } else {
            undoStack[undoStack.count - 1].time = now
        }
        redoStack.removeAll()
        document = next
        revision += 1
        return result
    }

    /// A continuous gesture such as a canvas drag: a snapshot is recorded at the start, `applyLive` modifies during it, and it is recorded as one step at the end.
    public mutating func beginGesture(_ name: String) {
        endGesture()
        gesture = (name, document)
    }

    public mutating func applyLive(_ change: (inout DesignDocument) -> Void) {
        applyLive(change, layingOutAll: false)
    }

    /// Lays out the whole document again, for when text measures differently (fonts were imported); like `applyLive`, it is
    /// not an undo step of its own.
    public mutating func layOutAgain() {
        applyLive({ _ in }, layingOutAll: true)
    }

    private mutating func applyLive(_ change: (inout DesignDocument) -> Void, layingOutAll: Bool) {
        var next = document
        change(&next)
        next.pruneAnnotations()
        DesignLayout.apply(to: &next.nodes, measure: measure, unchangedFrom: layingOutAll ? [] : document.nodes)
        guard next != document else { return }
        document = next
        revision += 1
    }

    public mutating func endGesture() {
        guard let gesture else { return }
        self.gesture = nil
        guard gesture.start != document else { return }
        push(Step(name: gesture.name, before: gesture.start, coalescing: nil))
        redoStack.removeAll()
    }

    @discardableResult
    public mutating func undo() -> Bool {
        endGesture()
        guard let step = undoStack.popLast() else { return false }
        redoStack.append(Step(name: step.name, before: document, coalescing: nil))
        document = step.before
        revision += 1
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        endGesture()
        guard let step = redoStack.popLast() else { return false }
        undoStack.append(Step(name: step.name, before: document, coalescing: nil))
        document = step.before
        revision += 1
        return true
    }

    /// New or open file: replaces the document and clears the history.
    public mutating func replace(_ next: DesignDocument) {
        gesture = nil
        undoStack.removeAll()
        redoStack.removeAll()
        var laidOut = next
        DesignLayout.apply(to: &laidOut.nodes, measure: measure)
        document = laidOut
        revision += 1
    }

    private mutating func push(_ step: Step) {
        undoStack.append(step)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
    }
}
