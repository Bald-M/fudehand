import Foundation

/// Keeps instances in step with their main components: records the overrides an edit made inside instances, then rebuilds the
/// instances whose main component (or own subtree) changed. Runs on every edit, so a document without components costs only a walk
/// over the subtrees the edit changed.
public enum ComponentSync {
    /// Test hook: counts `sync` calls made while a counter is bound.
    final class SyncCounter: @unchecked Sendable { var count = 0 }
    @TaskLocal static var syncCount: SyncCounter?

    /// Records overrides for edited instance layers, then rebuilds instances whose main component (or own subtree) changed.
    public static func reconcile(old: DesignDocument, new: inout DesignDocument) {
        var changes = Changes()
        changes.visit(new.nodes, old: old.nodes, path: [], instanceOf: nil)
        if !changes.edits.isEmpty { recordOverrides(changes.edits, in: &new) }
        if changes.components.isEmpty && changes.instances.isEmpty { return }
        var ids = FreshIDs(document: new)
        syncInstances(in: &new, changedComponents: changes.components, changedInstances: changes.instances, ids: &ids)
    }

    /// Builds instance layers for `component` with fresh ids (used by create-instance and paste).
    public static func makeInstance(of component: DesignNode, existing: inout Set<String>) -> DesignNode {
        var root = mirror(component) { take(&existing) }
        root.instance = component.id
        return root
    }

    /// Rebuilds one instance subtree from its main component, keeping overrides and the root's x/y.
    static func sync(_ instance: inout DesignNode, from component: DesignNode, existing: inout Set<String>) {
        sync(&instance, from: component) { take(&existing) }
    }

    /// Turns `node` and its layers into ordinary layers. Nested instance roots keep their `instance`.
    public static func detach(_ node: inout DesignNode) {
        func clear(_ layer: inout DesignNode, isTop: Bool) {
            if isTop { layer.instance = nil }
            layer.source = nil
            layer.overrides = []
            for index in layer.children.indices { clear(&layer.children[index], isTop: false) }
        }
        clear(&node, isTop: true)
    }

    /// Clears `properties` (all overrides when nil) on `node`, a layer inside an instance of `component`, and gives them back the
    /// values of its source layer. With nil on an instance root, every layer of the instance is reset; the root keeps its x/y.
    public static func resetOverrides(_ node: inout DesignNode, component: DesignNode, properties: Set<String>?) {
        let sources = layers(of: component)
        func reset(_ layer: inout DesignNode, recursive: Bool) {
            let source = layer.source.flatMap { sources[$0] }
            var paths = properties ?? layer.overrides
            for path in paths {
                if let dot = path.firstIndex(of: ".") {
                    // Resetting one field of a whole-object override keeps the object's other differing fields overridden.
                    let whole = String(path[..<dot])
                    guard layer.overrides.remove(whole) != nil else { continue }
                    let group = propertyGroups.first { $0.whole.path == whole }
                    for field in group?.fields ?? [] where !paths.contains(field.path) {
                        if let source, field.equal(layer, source) { continue }
                        layer.overrides.insert(field.path)
                    }
                } else {
                    // Resetting a whole object resets its fields too.
                    paths.formUnion(layer.overrides.filter { $0.hasPrefix(path + ".") })
                }
            }
            layer.overrides.subtract(paths)
            if let source {
                for path in paths where !(layer.instance != nil && rootOwned.contains(path)) {
                    ComponentProperty.named(path)?.copy(from: source, to: &layer)
                }
            }
            if recursive { for index in layer.children.indices { reset(&layer.children[index], recursive: true) } }
        }
        reset(&node, recursive: properties == nil && node.instance != nil)
    }

    // MARK: Finding changes

    /// The root's x and y belong to the instance: never synced, never overrides.
    private static let rootOwned: Set<String> = ["x", "y"]

    /// A layer inside an instance that the edit changed, with its value before the edit.
    private struct Edit {
        let path: [Int]
        let previous: DesignNode
        /// The main component of the instance the layer sits in.
        let component: String
    }

    /// One read-only walk over old and new that descends only into subtrees that differ.
    private struct Changes {
        /// Main components whose own subtree changed (moving the main component alone does not count).
        var components: Set<String> = []
        /// Index paths of instance roots whose own subtree changed (moving the instance alone does not count).
        var instances: [[Int]] = []
        /// Edited layers inside instances, whose overrides are recorded afterwards.
        var edits: [Edit] = []

        mutating func visit(_ new: [DesignNode], old: [DesignNode], path: [Int], instanceOf: String?) {
            if new == old { return }
            var oldByID: [String: DesignNode]?
            for (index, node) in new.enumerated() {
                let previous: DesignNode?
                if index < old.count, old[index].id == node.id {
                    previous = old[index]
                } else {
                    if oldByID == nil { oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
                    previous = oldByID?[node.id]
                }
                if let previous, previous == node { continue }
                if node.component || node.instance != nil {
                    let moved = previous.map { ComponentSync.differsOnlyInPosition($0, node) } ?? false
                    if node.component, !moved { components.insert(node.id) }
                    if node.instance != nil, !moved { instances.append(path + [index]) }
                }
                let owner = node.instance ?? instanceOf
                if let previous, node.source != nil, let owner {
                    edits.append(Edit(path: path + [index], previous: previous, component: owner))
                }
                visit(node.children, old: previous?.children ?? [], path: path + [index], instanceOf: owner)
            }
        }
    }

    /// Each changed property of an edited instance layer becomes an override, unless its new value equals the source layer's (new)
    /// value, which removes the override. All reads happen before the first write.
    private static func recordOverrides(_ edits: [Edit], in document: inout DesignDocument) {
        var updates: [(path: [Int], overrides: Set<String>)] = []
        do {
            var sourceLayers: [String: [String: DesignNode]] = [:]
            for edit in edits {
                let layer = document[edit.path]
                var paths = ComponentProperty.changed(edit.previous, layer)
                if layer.instance != nil { paths.subtract(rootOwned) }
                if paths.isEmpty { continue }
                if sourceLayers[edit.component] == nil {
                    let main = document.node(edit.component).flatMap { $0.component ? $0 : nil }
                    sourceLayers[edit.component] = main.map(layers(of:)) ?? [:]
                }
                guard let source = layer.source.flatMap({ sourceLayers[edit.component]?[$0] }) else { continue }
                var overrides = layer.overrides
                for path in paths {
                    guard let property = ComponentProperty.named(path) else { continue }
                    if property.equal(layer, source) { overrides.remove(path) } else { overrides.insert(path) }
                }
                if overrides != layer.overrides { updates.append((edit.path, overrides)) }
            }
        }
        for update in updates { document.update(at: update.path) { $0.overrides = update.overrides } }
    }

    private static func differsOnlyInPosition(_ old: DesignNode, _ new: DesignNode) -> Bool {
        var moved = old
        moved.x = new.x
        moved.y = new.y
        return moved == new
    }

    /// Every layer of `component`, the component itself included, by id.
    private static func layers(of component: DesignNode) -> [String: DesignNode] {
        var result: [String: DesignNode] = [:]
        func add(_ node: DesignNode) { result[node.id] = node; node.children.forEach(add) }
        add(component)
        return result
    }

    // MARK: Syncing

    /// Syncs every instance of a changed main component, and every changed instance, from its main component. Instances whose main
    /// component is missing (or is not one) are left as they are.
    private static func syncInstances(in document: inout DesignDocument, changedComponents: Set<String>, changedInstances: [[Int]],
                                      ids: inout FreshIDs) {
        var mains: [String: DesignNode?] = [:]
        func main(_ id: String) -> DesignNode? {
            if let cached = mains[id] { return cached }
            let found = document.node(id).flatMap { $0.component ? $0 : nil }
            mains[id] = found
            return found
        }
        for path in changedInstances {
            guard let componentID = document[path].instance, !changedComponents.contains(componentID),
                  let component = main(componentID) else { continue }
            document.update(at: path) { sync(&$0, from: component) { ids.next() } }
        }
        if changedComponents.isEmpty { return }
        let components = changedComponents.compactMap { id in main(id).map { (id, $0) } }
        let byID = Dictionary(uniqueKeysWithValues: components)
        if byID.isEmpty { return }
        func visit(_ nodes: inout [DesignNode]) {
            for index in nodes.indices {
                if let componentID = nodes[index].instance {
                    if let component = byID[componentID] { sync(&nodes[index], from: component) { ids.next() } }
                    continue
                }
                visit(&nodes[index].children)
            }
        }
        visit(&document.nodes)
    }

    private static func sync(_ instance: inout DesignNode, from component: DesignNode, newID: () -> String) {
        syncCount?.count += 1
        syncLayer(&instance, from: component, isRoot: true, newID: newID)
        instance.instance = component.id
    }

    /// Takes every property of `source` that `layer` does not override, then matches children by `source`: kept ones are synced,
    /// new ones are mirrored with fresh ids, gone ones are dropped, and the order follows `source`.
    private static func syncLayer(_ layer: inout DesignNode, from source: DesignNode, isRoot: Bool, newID: () -> String) {
        for group in propertyGroups {
            if isRoot && rootOwned.contains(group.whole.path) { continue }
            if layer.overrides.contains(group.whole.path) { continue }
            if group.fields.contains(where: { layer.overrides.contains($0.path) }) {
                for field in group.fields where !layer.overrides.contains(field.path) { field.copy(from: source, to: &layer) }
            } else {
                group.whole.copy(from: source, to: &layer)
            }
        }
        layer.source = source.id
        var existing: [String: DesignNode] = [:]
        for child in layer.children { if let id = child.source, existing[id] == nil { existing[id] = child } }
        layer.children = source.children.map { sourceChild in
            guard var child = existing[sourceChild.id] else { return mirror(sourceChild, newID: newID) }
            syncLayer(&child, from: sourceChild, isRoot: false, newID: newID)
            return child
        }
    }

    /// A copy of `source` and its layers with fresh ids, each pointing back at the layer it mirrors.
    private static func mirror(_ source: DesignNode, newID: () -> String) -> DesignNode {
        var layer = source
        layer.id = newID()
        layer.component = false
        layer.instance = nil
        layer.source = source.id
        layer.overrides = []
        layer.children = source.children.map { mirror($0, newID: newID) }
        return layer
    }

    /// A top-level property path with the field paths of its nested object (none for plain properties). Copying the whole object
    /// would overwrite overridden fields, so a group with a field override is copied field by field.
    private struct PropertyGroup {
        let whole: ComponentProperty
        let fields: [ComponentProperty]
    }

    private static let propertyGroups: [PropertyGroup] = {
        let fields = Dictionary(grouping: ComponentProperty.all.filter { $0.path.contains(".") }) {
            String($0.path.prefix { $0 != "." })
        }
        return ComponentProperty.all.filter { !$0.path.contains(".") }.map { PropertyGroup(whole: $0, fields: fields[$0.path] ?? []) }
    }()

    private static func take(_ existing: inout Set<String>) -> String {
        let id = DesignDocument.newID(existing: existing)
        existing.insert(id)
        return id
    }

    /// New ids for layers added by sync; the document's ids are collected only when the first one is needed.
    private struct FreshIDs {
        let document: DesignDocument
        private var taken: Set<String>?

        init(document: DesignDocument) { self.document = document }

        mutating func next() -> String {
            if taken == nil { taken = document.allIDs() }
            return ComponentSync.take(&taken!)
        }
    }
}
