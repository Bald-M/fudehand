import FudehandCore

/// Main components and instances (see "Components" in `docs/macos.md`). The UI and the control channel both call these.
extension FudehandStore {
    /// Turns a layer into a main component, as one undo step. Refused for a layer that is already one, an instance, or inside an
    /// instance or another main component, and for one holding a main component.
    @discardableResult
    func createComponent(_ id: String, step: String = "Create Component") throws -> DesignNode {
        let document = editor.document
        let chain = layers(from: document, to: id)
        guard let node = chain.last else { throw DesignError("Layer not found: \(id)") }
        if node.component { throw DesignError("Layer \(id) is already a main component") }
        if node.instance != nil { throw DesignError("Layer \(id) is an instance; detach it first") }
        for ancestor in chain.dropLast() {
            if ancestor.instance != nil { throw DesignError("Layer \(id) is inside instance \(ancestor.id); change its main component instead") }
            if ancestor.component {
                throw DesignError("Layer \(id) is inside main component \(ancestor.id); a main component cannot be inside another main component")
            }
        }
        var inner: String?
        DesignDocument(nodes: node.children).forEach { if inner == nil, $0.component { inner = $0.id } }
        if let inner { throw DesignError("Layer \(id) holds main component \(inner); a main component cannot be inside another main component") }
        try perform(step) { try $0.update(id) { $0.component = true } }
        return try layer(id)
    }

    /// Inserts an instance of a main component as one undo step and selects it. Without `at` it goes to the origin of `parent`; with
    /// neither, where an inserted layer goes (the selected frame, else the viewport center).
    @discardableResult
    func createInstance(of component: String, parent: String?, index: Int?, at point: Point?, step: String = "Insert Component") throws -> DesignNode {
        guard let main = editor.document.node(component) else { throw DesignError("Layer not found: \(component)") }
        guard main.component else { throw DesignError("Layer \(component) is not a main component") }
        var place: (parent: String?, x: Double, y: Double) = (parent, point?.x ?? 0, point?.y ?? 0)
        if parent == nil, point == nil { place = insertionPlacement(width: main.width, height: main.height) }
        var existing = editor.document.allIDs()
        var node = ComponentSync.makeInstance(of: main, existing: &existing)
        node.x = place.x
        node.y = place.y
        try perform(step) { try $0.insert(node, parent: place.parent, index: index) }
        setSelection([node.id])
        return try layer(node.id)
    }

    /// Every main component in document order, with the ids of its instance layers (nested copies included).
    func listComponents() -> [(component: DesignNode, instances: [String])] {
        var instances: [String: [String]] = [:]
        var components: [DesignNode] = []
        editor.document.forEach {
            if $0.component { components.append($0) }
            if let id = $0.instance { instances[id, default: []].append($0.id) }
        }
        return components.map { ($0, instances[$0.id] ?? []) }
    }

    /// Gives the properties of a layer inside an instance (all of them when nil; for an instance, every layer of it) back the
    /// values of the main component, as one undo step.
    @discardableResult
    func resetOverrides(_ id: String, properties: Set<String>?, step: String = "Reset Overrides") throws -> DesignNode {
        let document = editor.document
        let chain = layers(from: document, to: id)
        guard !chain.isEmpty else { throw DesignError("Layer not found: \(id)") }
        guard let root = chain.first(where: { $0.instance != nil }), let componentID = root.instance
        else { throw DesignError("Layer \(id) is not inside an instance") }
        guard let component = document.node(componentID), component.component else {
            throw DesignError("Layer \(root.id) has no main component \(componentID) to reset to")
        }
        if let unknown = properties?.sorted().first(where: { ComponentProperty.named($0) == nil }) { throw DesignError("Unknown property: \(unknown)") }
        try perform(step) { try $0.update(id) { ComponentSync.resetOverrides(&$0, component: component, properties: properties) } }
        return try layer(id)
    }

    /// Turns instances into ordinary layers, as one undo step; returns them in document order. Only instance roots can be detached.
    @discardableResult
    func detachInstances(_ ids: Set<String>, step: String = "Detach Instance") throws -> [DesignNode] {
        let before = editor.document
        for id in ids {
            let chain = layers(from: before, to: id)
            guard let node = chain.last else { throw DesignError("Layer not found: \(id)") }
            if node.instance != nil, node.source == node.instance { continue }
            if let root = chain.dropLast().first(where: { $0.instance != nil }) {
                throw DesignError("Layer \(id) is inside instance \(root.id); detach that instance instead")
            }
            throw DesignError("Layer \(id) is not an instance")
        }
        var order: [String] = []
        before.forEach { if ids.contains($0.id) { order.append($0.id) } }
        try perform(step) { document in
            for id in order { try document.update(id) { ComponentSync.detach(&$0, in: before) } }
        }
        return try order.map(layer)
    }

    /// The layers from the top level down to `id` (inclusive); empty when there is no such layer.
    private func layers(from document: DesignDocument, to id: String) -> [DesignNode] {
        document.ancestry(of: id).compactMap(document.node)
    }

    private func layer(_ id: String) throws -> DesignNode {
        guard let node = editor.document.node(id) else { throw DesignError("Layer not found: \(id)") }
        return node
    }
}
