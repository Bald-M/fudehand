import Foundation
import FudehandCore

/// Main components and instances (see "Components" in `docs/macos.md`). The UI and the control channel both call these.
extension FudehandStore {
    /// Turns a layer into a main component, as one undo step. Refused for a layer that is already one, an instance, or inside an
    /// instance or another main component, for one holding a main component, and for a component set or a layer holding one.
    @discardableResult
    func createComponent(_ id: String, step: String = "Create Component") throws -> DesignNode {
        if let refusal = createComponentRefusal(id) { throw refusal }
        try perform(step) { try $0.update(id) { $0.component = true } }
        return try layer(id)
    }

    /// Why layer `id` cannot become a main component, or nil when it can.
    private func createComponentRefusal(_ id: String) -> DesignError? {
        let index = self.index
        let chain = index.ancestry(of: id).compactMap(index.node)
        guard let node = chain.last else { return DesignError("Layer not found: \(id)") }
        if node.component { return DesignError("Layer \(id) is already a main component") }
        if node.instance != nil { return DesignError("Layer \(id) is an instance; detach it first") }
        if node.componentSet != nil { return DesignError("Layer \(id) is a component set; a component set cannot be a main component") }
        for ancestor in chain.dropLast() {
            if ancestor.instance != nil { return DesignError("Layer \(id) is inside instance \(ancestor.id); change its main component instead") }
            if ancestor.component {
                return DesignError("Layer \(id) is inside main component \(ancestor.id); a main component cannot be inside another main component")
            }
        }
        var inner: String?
        DesignDocument(nodes: node.children).forEach { if inner == nil, $0.component { inner = $0.id } }
        if let inner { return DesignError("Layer \(id) holds main component \(inner); a main component cannot be inside another main component") }
        var set: String?
        DesignDocument(nodes: node.children).forEach { if set == nil, $0.componentSet != nil { set = $0.id } }
        if let set { return DesignError("Layer \(id) contains component set \(set); a component set cannot be inside a main component") }
        return nil
    }

    /// Inserts an instance of a main component as one undo step and selects it. Without `at` it goes to the origin of `parent`; with
    /// neither, where an inserted layer goes (the selected frame, else the viewport center).
    @discardableResult
    func createInstance(of component: String, parent: String?, index: Int?, at point: Point?, step: String = "Insert Component") throws -> DesignNode {
        guard var main = editor.document.node(component) else { throw DesignError("Layer not found: \(component)") }
        // An instance of a component set is an instance of its first variant.
        if main.componentSet != nil, let first = main.children.first { main = first }
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

    /// Every component set in document order.
    func listComponentSets() -> [(id: String, name: String, properties: [String], variants: [DesignNode])] {
        var sets: [(id: String, name: String, properties: [String], variants: [DesignNode])] = []
        editor.document.forEach { if let properties = $0.componentSet { sets.append(($0.id, $0.name, properties, $0.children)) } }
        return sets
    }

    /// Wraps main components that share a parent in a new component set, as one undo step, and selects the set.
    @discardableResult
    func combineAsVariants(_ ids: [String], step: String = "Combine as Variants") throws -> DesignNode {
        var set = ""
        try perform(step) { set = try ComponentVariants.combine(ids, in: &$0, propertyName: L("Property 1")) }
        setSelection([set])
        return try layer(set)
    }

    /// Sets a component set's variant property names in order (see `ComponentVariants.setProperties`), as one undo step.
    @discardableResult
    func setVariantProperties(_ set: String, _ properties: [String], rename: [String: String], step: String = "Edit Variant Properties") throws -> DesignNode {
        try perform(step) {
            try ComponentVariants.setProperties(set, properties, rename: rename, defaultValue: L("Default"), in: &$0)
        }
        return try layer(set)
    }

    /// Sets some of a variant's values, as one undo step.
    @discardableResult
    func setVariant(_ id: String, values: [String: String], step: String = "Edit Variant") throws -> DesignNode {
        try perform(step) { try ComponentVariants.setValues(id, values, in: &$0) }
        return try layer(id)
    }

    /// Copies a variant, or a component set's last variant, into its set as a new variant, as one undo step, and selects it.
    @discardableResult
    func addVariant(_ id: String, step: String = "Add Variant") throws -> DesignNode {
        var added = ""
        try perform(step) { added = try ComponentVariants.addVariant(from: id, in: &$0) }
        setSelection([added])
        return try layer(added)
    }

    /// Switches instances to the variant with the given values, as one undo step, and selects them.
    @discardableResult
    func switchVariant(_ ids: [String], values: [String: String], step: String = "Switch Variant") throws -> [DesignNode] {
        try perform(step) { try ComponentVariants.switchInstances(ids, to: values, in: &$0) }
        setSelection(Set(ids))
        return try ids.map(layer)
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

    /// Whether any of these layers is below an instance's root. Structure there follows the main component, so the commands that
    /// insert, delete, move, or reorder layers are disabled for such a selection. The menus ask on every selection change, so this
    /// and the other checks the UI asks look layers up in the store's index instead of searching the tree.
    func hasLayersInsideInstance(_ ids: Set<String>) -> Bool {
        let index = self.index
        return ids.contains { id in index.ancestry(of: id).dropLast().contains { index.node($0)?.instance != nil } }
    }

    /// Whether Detach Instance applies to these layers: one or more, all instance roots.
    func canDetachInstances(_ ids: Set<String>) -> Bool {
        let index = self.index
        return !ids.isEmpty && ids.allSatisfy { id in index.node(id).map { $0.instance != nil && $0.source == $0.instance } ?? false }
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

    /// Whether *Reset Overrides* shows for a layer below an instance's root: it overrides properties itself, or it is a nested
    /// instance's root with overrides in its subtree.
    func showsResetOverrides(_ id: String) -> Bool {
        guard let node = index.node(id), node.source != nil, !(node.instance != nil && node.source == node.instance) else { return false }
        return !node.overrides.isEmpty || (node.instance != nil && Self.hasOverrides(node))
    }

    /// Whether the overrides of layer `id` can be reset: it is in an instance whose main component (the outermost instance's,
    /// which a reset goes back to) still exists.
    func canResetOverrides(_ id: String) -> Bool {
        let index = self.index
        guard index.node(id)?.source != nil,
              let root = index.ancestry(of: id).lazy.compactMap(index.node).first(where: { $0.instance != nil }),
              let component = root.instance else { return false }
        return index.node(component)?.component == true
    }

    /// Whether layer `node` or a layer below it overrides properties.
    nonisolated static func hasOverrides(_ node: DesignNode) -> Bool {
        !node.overrides.isEmpty || node.children.contains(where: hasOverrides)
    }

    /// Whether Combine as Variants applies to these layers: one or more main components that share a parent, none of them a
    /// variant already.
    func canCombineAsVariants(_ ids: Set<String>) -> Bool {
        let index = self.index
        guard let first = ids.first, let parent = index.parentID(of: first) else { return false }
        return ids.allSatisfy { id in
            guard index.node(id)?.component == true, index.parentID(of: id) == parent else { return false }
            return parent.flatMap(index.node)?.componentSet == nil
        }
    }

    func combineAsVariants(from ids: Set<String>) {
        guard canCombineAsVariants(ids) else { return }
        do { try combineAsVariants(ids.sorted()) } catch { alert = error.localizedDescription }
    }

    /// The variant properties of the component set that layer `id` is a variant of; nil when it is not a variant.
    func variantProperties(of id: String) -> [String]? {
        let index = self.index
        guard index.node(id)?.variant != nil, let parent = index.parentID(of: id) ?? nil else { return nil }
        return index.node(parent)?.componentSet
    }

    /// Adds a property named "Property n" (the lowest unused n) to component set `set`; every variant gets the value *Default*.
    func addVariantProperty(to set: String) {
        guard let properties = index.node(set)?.componentSet else { return }
        let name = (1...).lazy.map { L("Property %d", $0) }.first { !properties.contains($0) }!
        editVariantProperties(set, properties + [name], rename: [:])
    }

    /// Renames a property of component set `set`; an empty or unchanged name changes nothing.
    func renameVariantProperty(_ old: String, to new: String, in set: String) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, let properties = index.node(set)?.componentSet else { return }
        editVariantProperties(set, properties.map { $0 == old ? new : $0 }, rename: [old: new])
    }

    func removeVariantProperty(_ name: String, from set: String) {
        guard let properties = index.node(set)?.componentSet else { return }
        editVariantProperties(set, properties.filter { $0 != name }, rename: [:])
    }

    private func editVariantProperties(_ set: String, _ properties: [String], rename: [String: String]) {
        do { try setVariantProperties(set, properties, rename: rename) } catch { alert = error.localizedDescription }
    }

    /// Sets one value of variant `id`; an unchanged value changes nothing.
    func setVariantValue(_ id: String, property: String, value: String) {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard index.node(id)?.variant?[property] != value else { return }
        do { try setVariant(id, values: [property: value]) } catch { alert = error.localizedDescription }
    }

    /// Adds a variant copied from variant `id`, or from component set `id`'s last variant, and selects it.
    func addVariant(from id: String) {
        do { try addVariant(id) } catch { alert = error.localizedDescription }
    }

    /// For instance roots of variants of one component set: each property of the set with the values its variants use (in set
    /// order) and the instances' current value, nil when they differ. A current value the set's variants lack is listed last.
    /// Empty for any other selection.
    func variantChoices(of ids: Set<String>) -> [(property: String, values: [String], current: String?)] {
        let index = self.index
        var setID: String?
        var currents: [[String: String]] = []
        for id in ids {
            guard let node = index.node(id), let variantID = node.instance, node.source == variantID,
                  let current = index.node(variantID)?.variant, let parent = index.parentID(of: variantID) ?? nil,
                  setID == nil || setID == parent else { return [] }
            setID = parent
            currents.append(current)
        }
        guard let setID, let set = index.node(setID), let properties = set.componentSet else { return [] }
        return properties.map { property in
            var values: [String] = []
            for variant in set.children { if let value = variant.variant?[property], !values.contains(value) { values.append(value) } }
            let used = Set(currents.map { $0[property] ?? "" })
            let current = used.count == 1 ? used.first : nil
            if let current, !values.contains(current) { values.append(current) }
            return (property, values, current)
        }
    }

    /// Switches instances to the variant with `property` set to `value`, each keeping its other values where it can.
    func switchVariant(of ids: Set<String>, property: String, value: String) {
        do { try switchVariant(ids.sorted(), values: [property: value]) } catch { alert = error.localizedDescription }
    }

    /// What Insert Component lists, in document order: each component set that has a variant (previewed by its first variant)
    /// and each main component outside a set.
    func insertableComponents() -> [(id: String, name: String, preview: DesignNode)] {
        var entries: [(id: String, name: String, preview: DesignNode)] = []
        func visit(_ nodes: [DesignNode]) {
            for node in nodes {
                if node.componentSet != nil {
                    if let first = node.children.first, first.component { entries.append((node.id, node.name, first)) }
                } else if node.component {
                    entries.append((node.id, node.name, node))
                } else {
                    visit(node.children)
                }
            }
        }
        visit(editor.document.nodes)
        return entries
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
