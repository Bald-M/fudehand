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
        if let path, let root = enclosingInstance(path, includingLast: true) { throw insideInstance(node.id, root) }
        try checkInstanceCycles(node, under: path)
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

    /// Deletes nodes and their subtrees; when any id does not exist, or one is a layer inside an instance (below its root) whose
    /// instance is not deleted with it, nothing is deleted. Instances of the main components deleted are detached first, in the
    /// same change, unless `detachingInstances` is false (Cut, which leaves them pointing at the missing main component).
    public mutating func delete(_ ids: Set<String>, detachingInstances: Bool = true) throws {
        let existing = allIDs()
        if let missing = ids.sorted().first(where: { !existing.contains($0) }) { throw DesignError("Layer not found: \(missing)") }
        /// `root` is the outermost instance above `list`, nil when there is none or a deleted layer is above it.
        func checkStructure(_ list: [DesignNode], root: String?) throws {
            for node in list {
                if ids.contains(node.id) {
                    if let root { throw insideInstance(node.id, root) }
                    continue
                }
                try checkStructure(node.children, root: root ?? (node.instance != nil ? node.id : nil))
            }
        }
        try checkStructure(nodes, root: nil)
        if detachingInstances { detachInstances(ofComponentsIn: ids) }
        func prune(_ list: [DesignNode]) -> [DesignNode] {
            list.filter { !ids.contains($0.id) }.map { node in
                var copy = node
                copy.children = prune(node.children)
                return copy
            }
        }
        nodes = prune(nodes)
    }

    /// The outermost instance root among the layers along `path` (the last one only when `includingLast`): a layer below it is
    /// inside that instance, whose structure only its main component changes.
    private func enclosingInstance(_ path: [Int], includingLast: Bool) -> String? {
        var list = nodes
        for (depth, index) in path.enumerated() {
            if depth == path.count - 1 && !includingLast { break }
            if list[index].instance != nil { return list[index].id }
            list = list[index].children
        }
        return nil
    }

    private func insideInstance(_ id: String, _ root: String) -> DesignError {
        DesignError("Layer \(id) is inside instance \(root); change its main component instead")
    }

    /// Detaches the instances, outside the deleted subtrees, of the main components in them. Detaching an instance can leave the
    /// nested instances it held as instances of their own main component, so this repeats until none of a deleted one is left.
    private mutating func detachInstances(ofComponentsIn ids: Set<String>) {
        var removed: Set<String> = []
        func collect(_ list: [DesignNode], deleting: Bool) {
            for node in list {
                let deleting = deleting || ids.contains(node.id)
                if deleting && node.component { removed.insert(node.id) }
                collect(node.children, deleting: deleting)
            }
        }
        collect(nodes, deleting: false)
        if removed.isEmpty { return }
        while true {
            var roots: [[Int]] = []
            func find(_ list: [DesignNode], path: [Int]) {
                for (index, node) in list.enumerated() where !ids.contains(node.id) {
                    if let component = node.instance, node.source == component, removed.contains(component) {
                        roots.append(path + [index])
                    } else {
                        find(node.children, path: path + [index])
                    }
                }
            }
            find(nodes, path: [])
            if roots.isEmpty { return }
            let before = self
            for path in roots { update(at: path) { ComponentSync.detach(&$0, in: before) } }
        }
    }

    /// Refuses `node` under the layer at `parentPath` (nil for the top level) when an instance in it would end up inside its own
    /// main component, directly or through the instances that main component holds.
    private func checkInstanceCycles(_ node: DesignNode, under parentPath: [Int]?) throws {
        var enclosing: [String] = []
        if let parentPath {
            var list = nodes
            for index in parentPath {
                if list[index].component { enclosing.append(list[index].id) }
                list = list[index].children
            }
        }
        var inserted: [String: DesignNode] = [:]
        DesignDocument(nodes: [node]).forEach { if $0.component { inserted[$0.id] = $0 } }
        /// `id` and every main component whose instances its main component holds, directly or through nested instances.
        func reached(_ id: String) -> Set<String> {
            var result: Set<String> = []
            var stack = [id]
            while let next = stack.popLast() {
                guard result.insert(next).inserted, let main = inserted[next] ?? self.node(next), main.component else { continue }
                DesignDocument(nodes: main.children).forEach { if let used = $0.instance { stack.append(used) } }
            }
            return result
        }
        func check(_ layer: DesignNode, _ enclosing: [String]) throws {
            let enclosing = layer.component ? enclosing + [layer.id] : enclosing
            if let id = layer.instance, !enclosing.isEmpty, !reached(id).isDisjoint(with: enclosing) {
                throw DesignError("Layer \(layer.id): an instance cannot be inside its own main component")
            }
            for child in layer.children { try check(child, enclosing) }
        }
        try check(node, enclosing)
    }

    /// Moves to a new parent node (nil for the top level) and position, keeping the absolute position on the canvas. `index` is the position in the new parent after the node is removed.
    public mutating func move(_ id: String, parent: String?, index: Int?) throws {
        guard let path = indexPath(of: id), let world = worldRect(id) else { throw DesignError("Layer not found: \(id)") }
        if let parent, ancestry(of: parent).contains(id) { throw DesignError("Cannot move a layer into itself or its descendants") }
        var node = self[path]
        var copy = self
        try copy.delete([id], detachingInstances: false)
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
        /// The `measured` generation `before` was laid out in.
        let measured: Int
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
    private var gesture: (name: String, start: DesignDocument, measured: Int)?
    /// Counts `layOutAgain` calls: text measured differently from then on. A document laid out in an earlier generation (one
    /// undo or redo brings back) is laid out whole by the next edit, not only where the edit changed it (#228).
    private var measured = 0
    private var documentMeasured = 0
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
        defer { if let open { gesture = (open, document, documentMeasured) } }
        var next = document
        let result = try change(&next)
        ComponentSync.reconcile(old: document, new: &next)
        next.pruneAnnotations()
        DesignLayout.apply(to: &next.nodes, measure: measure, unchangedFrom: documentMeasured == measured ? document.nodes : [])
        guard next != document else { return result }
        let now = Date()
        if coalescing == nil || undoStack.last?.coalescing != coalescing || !redoStack.isEmpty
            || now.timeIntervalSince(undoStack.last?.time ?? .distantPast) > Self.coalescingWindow {
            push(Step(name: name, before: document, measured: documentMeasured, coalescing: coalescing, time: now))
        } else {
            undoStack[undoStack.count - 1].time = now
        }
        redoStack.removeAll()
        document = next
        documentMeasured = measured
        revision += 1
        return result
    }

    /// A continuous gesture such as a canvas drag: a snapshot is recorded at the start, `applyLive` modifies during it, and it is recorded as one step at the end.
    public mutating func beginGesture(_ name: String) {
        endGesture()
        gesture = (name, document, documentMeasured)
    }

    public mutating func applyLive(_ change: (inout DesignDocument) -> Void) {
        applyLive(change, layingOutAll: false)
    }

    /// Lays out the whole document again, for when text measures differently (fonts were imported); like `applyLive`, it is
    /// not an undo step of its own.
    public mutating func layOutAgain() {
        measured += 1
        applyLive({ _ in }, layingOutAll: true)
        documentMeasured = measured
    }

    private mutating func applyLive(_ change: (inout DesignDocument) -> Void, layingOutAll: Bool) {
        var next = document
        change(&next)
        ComponentSync.reconcile(old: document, new: &next)
        next.pruneAnnotations()
        DesignLayout.apply(to: &next.nodes, measure: measure, unchangedFrom: layingOutAll || documentMeasured != measured ? [] : document.nodes)
        documentMeasured = measured
        guard next != document else { return }
        document = next
        revision += 1
    }

    public mutating func endGesture() {
        guard let gesture else { return }
        self.gesture = nil
        guard gesture.start != document else { return }
        push(Step(name: gesture.name, before: gesture.start, measured: gesture.measured, coalescing: nil))
        redoStack.removeAll()
    }

    @discardableResult
    public mutating func undo() -> Bool {
        endGesture()
        guard let step = undoStack.popLast() else { return false }
        redoStack.append(Step(name: step.name, before: document, measured: documentMeasured, coalescing: nil))
        document = step.before
        documentMeasured = step.measured
        revision += 1
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        endGesture()
        guard let step = redoStack.popLast() else { return false }
        undoStack.append(Step(name: step.name, before: document, measured: documentMeasured, coalescing: nil))
        document = step.before
        documentMeasured = step.measured
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
        documentMeasured = measured
        revision += 1
    }

    private mutating func push(_ step: Step) {
        undoStack.append(step)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
    }
}
