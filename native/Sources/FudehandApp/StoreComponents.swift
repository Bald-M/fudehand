import FudehandCore

/// Main components and instances (see "Components" in `docs/macos.md`). The UI and the control channel both call these.
extension FudehandStore {
    /// Turns a layer into a main component, as one undo step. Refused for a layer that is already one, an instance, or inside an
    /// instance or another main component, and for one holding a main component.
    @discardableResult
    func createComponent(_ id: String, step: String = "Create Component") throws -> DesignNode {
        if let refusal = createComponentRefusal(id) { throw refusal }
        try perform(step) { try $0.update(id) { $0.component = true } }
        return try layer(id)
    }

    /// Why layer `id` cannot become a main component, or nil when it can.
    private func createComponentRefusal(_ id: String) -> DesignError? {
        let chain = layers(from: editor.document, to: id)
        guard let node = chain.last else { return DesignError("Layer not found: \(id)") }
        if node.component { return DesignError("Layer \(id) is already a main component") }
        if node.instance != nil { return DesignError("Layer \(id) is an instance; detach it first") }
        for ancestor in chain.dropLast() {
            if ancestor.instance != nil { return DesignError("Layer \(id) is inside instance \(ancestor.id); change its main component instead") }
            if ancestor.component {
                return DesignError("Layer \(id) is inside main component \(ancestor.id); a main component cannot be inside another main component")
            }
        }
        var inner: String?
        DesignDocument(nodes: node.children).forEach { if inner == nil, $0.component { inner = $0.id } }
        if let inner { return DesignError("Layer \(id) holds main component \(inner); a main component cannot be inside another main component") }
        return nil
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

    // The UI entry points: the Edit menu, the layers panel, the properties panel, and the Insert Component popover. They show an
    // error in an alert.

    /// Whether Create Component applies to these layers: exactly one, which can become a main component.
    func canCreateComponent(_ ids: Set<String>) -> Bool {
        ids.count == 1 && ids.first.flatMap(createComponentRefusal) == nil
    }

    /// Whether Detach Instance applies to these layers: one or more, all instance roots.
    func canDetachInstances(_ ids: Set<String>) -> Bool {
        let document = editor.document
        return !ids.isEmpty && ids.allSatisfy { id in document.node(id).map { $0.instance != nil && $0.source == $0.instance } ?? false }
    }

    func createComponent(from ids: Set<String>) {
        guard canCreateComponent(ids), let id = ids.first else { return }
        do { try createComponent(id) } catch { alert = error.localizedDescription }
    }

    func detachInstances(from ids: Set<String>) {
        guard canDetachInstances(ids) else { return }
        do { try detachInstances(ids) } catch { alert = error.localizedDescription }
    }

    /// Inserts an instance of main component `id` where Insert Icon puts an icon, and selects it.
    func insertComponent(_ id: String) {
        do { try createInstance(of: id, parent: nil, index: nil, at: nil) } catch { alert = error.localizedDescription }
    }

    /// Resets the given properties of a layer inside an instance; nil resets all of them (for an instance root, on every layer of it).
    func resetOverrides(of id: String, _ properties: Set<String>?) {
        do { try resetOverrides(id, properties: properties) } catch { alert = error.localizedDescription }
    }

    /// Selects every instance of main component `id`.
    func selectInstances(of id: String) {
        setSelection(Set(listComponents().first { $0.component.id == id }?.instances ?? []))
    }

    /// Selects the main component of instance `id` and brings it into view.
    func goToMainComponent(of id: String) {
        guard let component = editor.document.node(id)?.instance, editor.document.node(component)?.component == true else { return }
        setSelection([component])
        focus(component)
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
