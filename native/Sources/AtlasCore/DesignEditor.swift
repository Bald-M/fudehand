import Foundation

// MARK: Tree operations

extension DesignDocument {
    /// 节点在树中的下标路径。
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

    /// 外层 nil 表示找不到节点，内层 nil 表示顶层节点。
    public func parentID(of id: String) -> String?? {
        guard let path = indexPath(of: id) else { return nil }
        return .some(path.count == 1 ? nil : self[Array(path.dropLast())].id)
    }

    /// 从顶层到该节点（含）的 id 列表。
    public func ancestry(of id: String) -> [String] {
        guard let path = indexPath(of: id) else { return [] }
        return (1...path.count).map { self[Array(path.prefix($0))].id }
    }

    /// 节点在画布上的绝对矩形。
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
        guard let path = indexPath(of: parent) else { throw DesignError("找不到图层：\(parent)") }
        let node = self[path]
        guard node.type.hasChildren else { throw DesignError("图层 \(parent) 不能包含子图层") }
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
        if let duplicate { throw DesignError("图层 id 重复：\(duplicate)") }
        try DesignDocument(nodes: [node]).validateUniqueIDs()
        let position = index ?? list.count
        guard (0...list.count).contains(position) else { throw DesignError("index 超出范围：0–\(list.count)") }
        var next = list
        next.insert(node, at: position)
        setChildren(next, at: path)
    }

    public mutating func update(_ id: String, _ change: (inout DesignNode) throws -> Void) throws {
        guard let path = indexPath(of: id) else { throw DesignError("找不到图层：\(id)") }
        var node = self[path]
        try change(&node)
        self[path] = node
    }

    /// 删除节点及其子树；任何一个 id 不存在时什么都不删。
    public mutating func delete(_ ids: Set<String>) throws {
        let existing = allIDs()
        if let missing = ids.sorted().first(where: { !existing.contains($0) }) { throw DesignError("找不到图层：\(missing)") }
        func prune(_ list: [DesignNode]) -> [DesignNode] {
            list.filter { !ids.contains($0.id) }.map { node in
                var copy = node
                copy.children = prune(node.children)
                return copy
            }
        }
        nodes = prune(nodes)
    }

    /// 移动到新的父节点（nil 为顶层）与位置，保持画布上的绝对位置。`index` 是移出后在新父节点中的位置。
    public mutating func move(_ id: String, parent: String?, index: Int?) throws {
        guard let path = indexPath(of: id), let world = worldRect(id) else { throw DesignError("找不到图层：\(id)") }
        if let parent, ancestry(of: parent).contains(id) { throw DesignError("不能把图层移动到它自己或子图层中") }
        var node = self[path]
        var copy = self
        try copy.delete([id])
        let origin = try parent.map { parent -> Rect in
            guard let rect = copy.worldRect(parent) else { throw DesignError("找不到图层：\(parent)") }
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

    /// 给 JSON 形式的新节点及其子节点补上缺少的 id，用于 Agent 创建图层。
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

/// 文档与撤销历史。人工编辑与 Agent 编辑共用一条历史；每次修改后重新布局。
public struct DesignEditor {
    private struct Step {
        let name: String
        let before: DesignDocument
        let coalescing: String?
        var time = Date()
    }
    /// 相同合并键的修改在这段时间内连续发生才合并为一步。
    public static let coalescingWindow: TimeInterval = 1.5

    public private(set) var document: DesignDocument
    /// 每次文档变化（含撤销、重做、替换）递增。
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

    /// 一次修改为一步撤销；修改抛错或没有变化时文档与历史都不变。相同 `coalescing` 的连续修改合并为一步。
    @discardableResult
    /// 连续操作进行中（例如拖动时 Agent 发来修改）时，先把已拖动的部分记为一步，修改后从新状态继续记录这次拖动。
    public mutating func perform<T>(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> T) rethrows -> T {
        let open = gesture?.name
        endGesture()
        defer { if let open { gesture = (open, document) } }
        var next = document
        let result = try change(&next)
        DesignLayout.apply(to: &next.nodes, measure: measure)
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

    /// 画布拖动等连续操作：开始时记录快照，过程中用 `applyLive` 修改，结束时记为一步。
    public mutating func beginGesture(_ name: String) {
        endGesture()
        gesture = (name, document)
    }

    public mutating func applyLive(_ change: (inout DesignDocument) -> Void) {
        var next = document
        change(&next)
        DesignLayout.apply(to: &next.nodes, measure: measure)
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

    /// 新建或打开文件：替换文档并清空历史。
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
