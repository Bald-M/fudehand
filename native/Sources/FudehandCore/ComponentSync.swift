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
        changes.visit(new.nodes, old: old.nodes, path: [], root: nil, instanceOf: nil)
        if !changes.edits.isEmpty { recordOverrides(changes.edits, in: &new) }
        if changes.components.isEmpty && changes.instances.isEmpty { return }
        var ids = FreshIDs(document: new)
        syncInstances(in: &new, changedComponents: changes.components, changedInstances: changes.instances, ids: &ids)
    }

    /// Builds instance layers for `component` with fresh ids (used by create-instance and paste).
    public static func makeInstance(of component: DesignNode, existing: inout Set<String>) -> DesignNode {
        var root = mirror(component) { take(&existing) }
        root.instance = component.id
        rewriteTargets(&root)
        return root
    }

    /// Rebuilds one instance subtree from its main component, keeping overrides and the root's x/y.
    static func sync(_ instance: inout DesignNode, from component: DesignNode, existing: inout Set<String>) {
        sync(&instance, from: component) { take(&existing) }
    }

    /// Turns `node` and its layers into ordinary layers. Nested instances of other components stay instances: their layers'
    /// `source` moves from the layers of `node`'s main component to the layers of their own main component, and their
    /// `overrides` become the properties whose values differ from those layers. `document` holds the main components.
    public static func detach(_ node: inout DesignNode, in document: DesignDocument) {
        let outer = node.instance.flatMap { document.node($0) }.map(layers(of:)) ?? [:]
        func clear(_ layer: inout DesignNode, isTop: Bool) {
            if !isTop, let nested = layer.instance {
                relink(&layer, to: nested)
                return
            }
            if isTop { layer.instance = nil }
            layer.source = nil
            layer.overrides = []
            for index in layer.children.indices { clear(&layer.children[index], isTop: false) }
        }
        func relink(_ copy: inout DesignNode, to componentID: String) {
            func resolve(_ layer: inout DesignNode) {
                layer.source = layer.source.flatMap { outer[$0]?.source }
                for index in layer.children.indices { resolve(&layer.children[index]) }
            }
            resolve(&copy)
            copy.source = componentID
            let sources = document.node(componentID).flatMap { $0.component ? layers(of: $0) : nil } ?? [:]
            let ids = instanceLayerIDs(copy)
            func recompute(_ layer: inout DesignNode, isRoot: Bool) {
                if let source = layer.source.flatMap({ sources[$0] }) {
                    var paths = ComponentProperty.changed(source, layer)
                    if paths.contains("interaction"), layer.interaction == rewritten(source.interaction, ids) {
                        paths.remove("interaction")
                    }
                    if isRoot { paths.subtract(rootOwned) }
                    layer.overrides = paths
                } else {
                    layer.overrides = []
                }
                for index in layer.children.indices { recompute(&layer.children[index], isRoot: false) }
            }
            recompute(&copy, isRoot: true)
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
                for path in paths where !(isInstanceRoot(layer) && rootOwned.contains(path)) {
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

    /// An instance root follows its main component itself; a nested instance copied into another instance has `instance` set too,
    /// but its `source` is a layer of the outer main component.
    private static func isInstanceRoot(_ layer: DesignNode) -> Bool { layer.instance != nil && layer.source == layer.instance }

    /// A layer inside an instance that the edit changed, with its value before the edit.
    private struct Edit {
        let path: [Int]
        let previous: DesignNode
        /// The index path of the instance root the layer sits in (the outermost one for layers of nested copies).
        let root: [Int]
        /// The main component of that instance, which holds every source layer of it.
        let component: String
    }

    /// One read-only walk over old and new that descends only into subtrees that differ.
    private struct Changes {
        /// Main components whose own subtree changed (moving the main component alone does not count).
        var components: Set<String> = []
        /// Index paths of instance roots whose own subtree changed (moving the instance alone does not count). Nested instances
        /// copied into another instance are not roots: they follow the outer instance's main component.
        var instances: [[Int]] = []
        /// Edited layers inside instances, whose overrides are recorded afterwards.
        var edits: [Edit] = []

        /// `root` and `instanceOf` are the outermost instance root above `new` and its main component.
        mutating func visit(_ new: [DesignNode], old: [DesignNode], path: [Int], root: [Int]?, instanceOf: String?) {
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
                let isRoot = instanceOf == nil && node.instance != nil
                if node.component || isRoot {
                    let moved = previous.map { ComponentSync.differsOnlyInPosition($0, node) } ?? false
                    if node.component, !moved { components.insert(node.id) }
                    if isRoot, !moved { instances.append(path + [index]) }
                }
                let owner = instanceOf ?? node.instance
                let ownerRoot = isRoot ? path + [index] : root
                if let previous, node.source != nil, let owner, let ownerRoot {
                    edits.append(Edit(path: path + [index], previous: previous, root: ownerRoot, component: owner))
                }
                visit(node.children, old: previous?.children ?? [], path: path + [index], root: ownerRoot, instanceOf: owner)
            }
        }
    }

    /// Each changed property of an edited instance layer becomes an override, unless its new value equals the source layer's (new)
    /// value, which removes the override. Toggle targets are compared after rewriting the source's into the instance's layers.
    /// All reads happen before the first write.
    private static func recordOverrides(_ edits: [Edit], in document: inout DesignDocument) {
        var updates: [(path: [Int], overrides: Set<String>)] = []
        do {
            var sourceLayers: [String: [String: DesignNode]] = [:]
            var targetIDs: [[Int]: [String: String]] = [:]
            for edit in edits {
                let layer = document[edit.path]
                var paths = ComponentProperty.changed(edit.previous, layer)
                if edit.path == edit.root { paths.subtract(rootOwned) }
                if paths.isEmpty { continue }
                if sourceLayers[edit.component] == nil {
                    let main = document.node(edit.component).flatMap { $0.component ? $0 : nil }
                    sourceLayers[edit.component] = main.map(layers(of:)) ?? [:]
                }
                guard let source = layer.source.flatMap({ sourceLayers[edit.component]?[$0] }) else { continue }
                var overrides = layer.overrides
                for path in paths {
                    guard let property = ComponentProperty.named(path) else { continue }
                    let equal: Bool
                    if path == "interaction" {
                        if targetIDs[edit.root] == nil { targetIDs[edit.root] = instanceLayerIDs(document[edit.root]) }
                        equal = layer.interaction == rewritten(source.interaction, targetIDs[edit.root] ?? [:])
                    } else {
                        equal = property.equal(layer, source)
                    }
                    if equal { overrides.remove(path) } else { overrides.insert(path) }
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

    /// Syncs every instance of a changed main component, and every changed instance, from its main component. A main component
    /// holding instances of another is synced after it, and becomes changed when they are. Instances whose main component is
    /// missing (or is not one), and main components on a cycle of instances, are left as they are.
    private static func syncInstances(in document: inout DesignDocument, changedComponents: Set<String>, changedInstances: [[Int]],
                                      ids: inout FreshIDs) {
        let graph = ComponentGraph(document.nodes)
        let order = graph.order()
        let synced = Set(order)
        for path in changedInstances {
            guard let componentID = document[path].instance, !changedComponents.contains(componentID), synced.contains(componentID),
                  let mainPath = graph.mains[componentID] else { continue }
            let component = document[mainPath]
            document.update(at: path) { sync(&$0, from: component) { ids.next() } }
        }
        var changed = changedComponents
        for componentID in order where changed.contains(componentID) {
            guard let mainPath = graph.mains[componentID] else { continue }
            // Read after the instances inside it were synced.
            let component = document[mainPath]
            for instance in graph.instances[componentID] ?? [] {
                document.update(at: instance.path) { sync(&$0, from: component) { ids.next() } }
                if let container = instance.container { changed.insert(container) }
            }
        }
    }

    /// Where the main components and the instance roots of a document are, and which main components hold instances of which.
    /// Instance roots are those not inside another instance; nested copies follow their outer instance.
    private struct ComponentGraph {
        var mains: [String: [Int]] = [:]
        /// Instance roots by main component, each with the main component it sits in, if any.
        var instances: [String: [(path: [Int], container: String?)]] = [:]
        /// Main component → the main components whose instances it holds.
        var uses: [String: Set<String>] = [:]

        init(_ nodes: [DesignNode]) { walk(nodes, path: [], container: nil) }

        private mutating func walk(_ nodes: [DesignNode], path: [Int], container: String?) {
            for (index, node) in nodes.enumerated() {
                let nodePath = path + [index]
                if let componentID = node.instance {
                    instances[componentID, default: []].append((nodePath, container))
                    if let container { uses[container, default: []].insert(componentID) }
                    continue
                }
                var inner = container
                if node.component {
                    if mains[node.id] == nil { mains[node.id] = nodePath }
                    inner = node.id
                }
                walk(node.children, path: nodePath, container: inner)
            }
        }

        /// The main components in sync order (one holding instances of another after it), without those on a cycle.
        func order() -> [String] {
            func reachesItself(_ id: String) -> Bool {
                var seen: Set<String> = []
                var stack = Array(uses[id] ?? [])
                while let next = stack.popLast() {
                    if next == id { return true }
                    if seen.insert(next).inserted { stack += uses[next] ?? [] }
                }
                return false
            }
            let cyclic = Set(mains.keys.filter(reachesItself))
            var result: [String] = []
            var done: Set<String> = []
            func add(_ id: String) {
                guard !cyclic.contains(id), mains[id] != nil, done.insert(id).inserted else { return }
                for used in (uses[id] ?? []).sorted() { add(used) }
                result.append(id)
            }
            for id in mains.keys.sorted() { add(id) }
            return result
        }
    }

    private static func sync(_ instance: inout DesignNode, from component: DesignNode, newID: () -> String) {
        syncCount?.count += 1
        syncLayer(&instance, from: component, isRoot: true, newID: newID)
        instance.instance = component.id
        rewriteTargets(&instance)
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
        if !isRoot { layer.instance = source.instance }
        var existing: [String: DesignNode] = [:]
        for child in layer.children { if let id = child.source, existing[id] == nil { existing[id] = child } }
        layer.children = source.children.map { sourceChild in
            guard var child = existing[sourceChild.id] else { return mirror(sourceChild, newID: newID) }
            syncLayer(&child, from: sourceChild, isRoot: false, newID: newID)
            return child
        }
    }

    /// A copy of `source` and its layers with fresh ids, each pointing back at the layer it mirrors. Nested instance roots keep
    /// their `instance`.
    private static func mirror(_ source: DesignNode, newID: () -> String) -> DesignNode {
        var layer = source
        layer.id = newID()
        layer.component = false
        layer.source = source.id
        layer.overrides = []
        layer.children = source.children.map { mirror($0, newID: newID) }
        return layer
    }

    // MARK: References inside a component

    /// The instance's layer ids by the id of the main component layer each mirrors.
    private static func instanceLayerIDs(_ root: DesignNode) -> [String: String] {
        var result: [String: String] = [:]
        func add(_ layer: DesignNode) {
            if let source = layer.source { result[source] = layer.id }
            layer.children.forEach(add)
        }
        add(root)
        return result
    }

    /// Toggle targets among `ids`' keys become the matching instance layers; other targets and interactions stay as they are.
    private static func rewritten(_ interaction: DesignInteraction?, _ ids: [String: String]) -> DesignInteraction? {
        guard case .toggleVisibility(let targets) = interaction else { return interaction }
        return .toggleVisibility(targets: targets.map { ids[$0] ?? $0 })
    }

    /// Points the toggle targets that the instance's layers took from the main component at the instance's own layers.
    private static func rewriteTargets(_ root: inout DesignNode) {
        let ids = instanceLayerIDs(root)
        func visit(_ layer: inout DesignNode) {
            if !layer.overrides.contains("interaction"), case .toggleVisibility = layer.interaction {
                let next = rewritten(layer.interaction, ids)
                if next != layer.interaction { layer.interaction = next }
            }
            for index in layer.children.indices { visit(&layer.children[index]) }
        }
        visit(&root)
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
