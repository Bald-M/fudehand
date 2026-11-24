import Foundation

/// Editing component sets (see "Variants and component sets" in the variants spec): combining main components into a set,
/// editing its variant properties and a variant's values, and adding variants. Combine and add are the only ways a main
/// component goes into a set; `DesignDocument.insert` and `move` refuse moving layers into or out of one.
public enum ComponentVariants {
    /// The space between a component set's edge and its variants, and between a copied variant and the one it copies.
    static let padding = 16.0

    /// Wraps main components that share a parent and are not variants in a new component set placed at their union rectangle
    /// plus `padding`, keeping their ids and canvas positions. The set is named after the first of them in stacking order and
    /// has one property, `propertyName`, whose values are their names made unique. Returns the set's id.
    public static func combine(_ ids: [String], in document: inout DesignDocument, propertyName: String) throws -> String {
        guard !ids.isEmpty else { throw DesignError("No main components to combine") }
        var shared: (parent: String?, first: String)?
        for id in ids {
            guard let node = document.node(id) else { throw DesignError("Layer not found: \(id)") }
            guard node.component else { throw DesignError("Layer \(id) is not a main component") }
            if let set = set(of: id, in: document) { throw DesignError("Layer \(id) is already a variant of component set \(set)") }
            let parent = document.parentID(of: id)!
            if let shared, shared.parent != parent { throw DesignError("Layers \(shared.first) and \(id) do not share a parent") }
            if shared == nil { shared = (parent, id) }
        }
        guard !propertyName.isEmpty else { throw DesignError("Variant property names cannot be empty") }
        let parentPath = shared!.parent.flatMap(document.indexPath(of:))
        var siblings = parentPath.map { document[$0].children } ?? document.nodes
        let chosen = Set(ids)
        let members = siblings.filter { chosen.contains($0.id) }
        let position = siblings.firstIndex { chosen.contains($0.id) }!
        let bounds = Rect.union(members.map(\.frame))!
        var set = DesignNode(id: DesignDocument.newID(existing: document.allIDs()), type: .frame, name: members[0].name,
                             x: bounds.x - padding, y: bounds.y - padding,
                             width: bounds.width + 2 * padding, height: bounds.height + 2 * padding)
        set.componentSet = [propertyName]
        var used: Set<String> = []
        set.children = members.map { member in
            var variant = member
            variant.x -= set.x
            variant.y -= set.y
            let value = uniqueValue(member.name.isEmpty ? member.type.title : member.name, among: used)
            used.insert(value)
            variant.variant = [propertyName: value]
            return variant
        }
        siblings.removeAll { chosen.contains($0.id) }
        siblings.insert(set, at: position)
        if let parentPath { document[parentPath].children = siblings } else { document.nodes = siblings }
        return set.id
    }

    /// Sets a component set's property names in order. `rename` maps current names to new ones; a listed name that is neither
    /// current nor a rename target is added with `defaultValue` on every variant, and a current name not listed (nor renamed) is
    /// removed. Refused when two variants would then have the same values.
    public static func setProperties(_ setID: String, _ properties: [String], rename: [String: String], defaultValue: String,
                                     in document: inout DesignDocument) throws {
        guard let path = document.indexPath(of: setID) else { throw DesignError("Layer not found: \(setID)") }
        var set = document[path]
        guard let current = set.componentSet else { throw DesignError("Layer \(setID) is not a component set") }
        for old in rename.keys.sorted() where !current.contains(old) {
            throw DesignError("Component set \(setID) has no variant property \(old)")
        }
        var names: Set<String> = []
        for name in properties {
            if name.isEmpty { throw DesignError("Variant property names cannot be empty") }
            if !names.insert(name).inserted { throw DesignError("Duplicate variant property \(name)") }
        }
        var renamedFrom: [String: String] = [:]
        for (old, new) in rename.sorted(by: { $0.key < $1.key }) {
            if renamedFrom[new] != nil { throw DesignError("Duplicate variant property \(new)") }
            renamedFrom[new] = old
        }
        if properties.isEmpty && !set.children.isEmpty {
            throw DesignError("Component set \(setID) needs at least one variant property")
        }
        guard !defaultValue.isEmpty else { throw DesignError("Variant values cannot be empty") }
        /// The current property whose values `name` takes, if any.
        func origin(_ name: String) -> String? {
            if let old = renamedFrom[name] { return old }
            return current.contains(name) && rename[name] == nil ? name : nil
        }
        set.componentSet = properties
        for index in set.children.indices {
            let old = set.children[index].variant ?? [:]
            set.children[index].variant = Dictionary(uniqueKeysWithValues: properties.map { name in
                (name, origin(name).flatMap { old[$0] } ?? defaultValue)
            })
        }
        var seen: [[String]: String] = [:]
        for child in set.children {
            let values = properties.map { child.variant?[$0] ?? "" }
            if let other = seen[values] {
                throw DesignError("Variants \(other) and \(child.id) of component set \(setID) would have the same values")
            }
            seen[values] = child.id
        }
        document[path] = set
    }

    /// Sets some of a variant's values; refused when another variant of its set would have the same values.
    public static func setValues(_ variantID: String, _ values: [String: String], in document: inout DesignDocument) throws {
        guard document.node(variantID) != nil else { throw DesignError("Layer not found: \(variantID)") }
        guard let setID = set(of: variantID, in: document), let path = document.indexPath(of: setID) else {
            throw DesignError("Layer \(variantID) is not a variant")
        }
        var set = document[path]
        let properties = set.componentSet ?? []
        for key in values.keys.sorted() where !properties.contains(key) {
            throw DesignError("Component set \(setID) has no variant property \(key)")
        }
        if values.values.contains(where: \.isEmpty) { throw DesignError("Variant values cannot be empty") }
        let index = set.children.firstIndex { $0.id == variantID }!
        set.children[index].variant?.merge(values) { $1 }
        let key = { (node: DesignNode) in properties.map { node.variant?[$0] ?? "" } }
        let mine = key(set.children[index])
        if let other = set.children.first(where: { $0.id != variantID && key($0) == mine }) {
            throw DesignError("Variant \(variantID) would have the same values as variant \(other.id)")
        }
        document[path] = set
    }

    /// Add Variant: copies the variant `id` (or, for a component set, its last variant) with new ids into the set just after it,
    /// `padding` below it, with its first property's value made unique, and grows the set to include it. Returns the new id.
    public static func addVariant(from id: String, in document: inout DesignDocument) throws -> String {
        guard let node = document.node(id) else { throw DesignError("Layer not found: \(id)") }
        let setID: String, source: DesignNode
        if node.componentSet != nil {
            guard let last = node.children.last else { throw DesignError("Component set \(id) has no variants to copy") }
            (setID, source) = (id, last)
        } else if let owner = set(of: id, in: document) {
            (setID, source) = (owner, node)
        } else {
            throw DesignError("Layer \(id) is not a variant or a component set")
        }
        var existing = document.allIDs()
        let copy = freshCopies([source], existing: &existing)[0]
        return try insertVariant(copy, values: source.variant ?? [:], fallback: source.name, into: setID, after: source.id,
                                 in: &document)
    }

    // MARK: Switching

    /// The variant chosen when `instanceVariant`'s values change by `changes`: the variant with exactly the changed values, else
    /// the one with the changed values that shares the most other values with `instanceVariant` (ties: the first in set order).
    /// Nil when `instanceVariant` is not a variant or no variant of its set has the changed values.
    public static func target(for instanceVariant: String, changing changes: [String: String],
                              in document: DesignDocument) -> String? {
        guard let setID = set(of: instanceVariant, in: document), let set = document.node(setID),
              let current = document.node(instanceVariant)?.variant else { return nil }
        let wanted = current.merging(changes) { $1 }
        if let exact = set.children.first(where: { $0.variant == wanted }) { return exact.id }
        let others = (set.componentSet ?? []).filter { changes[$0] == nil }
        var best: (id: String, shared: Int)?
        for variant in set.children {
            let values = variant.variant ?? [:]
            guard changes.allSatisfy({ values[$0.key] == $0.value }) else { continue }
            let shared = others.filter { values[$0] == current[$0] }.count
            if shared > best?.shared ?? -1 { best = (variant.id, shared) }
        }
        return best?.id
    }

    /// Switches each instance root in `ids` to the variant `target` picks from its own current variant and `changes`. The root
    /// keeps its id, x/y, and overrides; each layer below it is paired with the layer of the new variant at the same name path
    /// (same-named siblings in order) and keeps its id, annotations, and the overrides the new layer has. Unmatched layers are
    /// removed and new ones added with fresh ids. Refused, changing nothing, when a layer is not an instance root of a variant
    /// or its set has no variant with the changed values.
    public static func switchInstances(_ ids: [String], to changes: [String: String], in document: inout DesignDocument) throws {
        var next = document
        var existing = next.allIDs()
        for id in ids {
            guard let path = next.indexPath(of: id) else { throw DesignError("Layer not found: \(id)") }
            let old = next[path]
            guard let current = old.instance, old.source == current else { throw DesignError("Layer \(id) is not an instance") }
            guard let setID = set(of: current, in: next) else {
                throw DesignError("Layer \(id) is an instance of \(current), which is not a variant")
            }
            guard let target = target(for: current, changing: changes, in: next) else {
                let wanted = changes.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: ", ")
                throw DesignError("Component set \(setID) has no variant with \(wanted)")
            }
            if target == current { continue }
            var switched = ComponentSync.makeInstance(of: next.node(target)!, existing: &existing)
            var renamed: [String: String] = [:]
            carry(old, onto: &switched, renamed: &renamed, in: next)
            switched.x = old.x
            switched.y = old.y
            // makeInstance pointed toggle targets at the fresh ids, and matched layers took back their old ids; targets that
            // carried overrides name on unmatched (removed) layers are dropped.
            let removed = DesignDocument(nodes: [old]).allIDs().subtracting(DesignDocument(nodes: [switched]).allIDs())
            func retarget(_ layer: inout DesignNode) {
                if case .toggleVisibility(let targets) = layer.interaction,
                   targets.contains(where: { renamed[$0] != nil || removed.contains($0) }) {
                    let next = targets.map { renamed[$0] ?? $0 }.filter { !removed.contains($0) }
                    layer.interaction = next.isEmpty ? nil : .toggleVisibility(targets: next)
                }
                for index in layer.children.indices { retarget(&layer.children[index]) }
            }
            retarget(&switched)
            next[path] = switched
        }
        document = next
    }

    /// Gives `new`, a layer built from the new variant, the id of `old`, the layer it matched, with the values and overrides of
    /// `old`'s overrides that exist on `new` (only the `typeIndependent` ones when their types differ); then pairs their children
    /// by name. `renamed` maps replaced ids to the kept ones.
    private static func carry(_ old: DesignNode, onto new: inout DesignNode, renamed: inout [String: String],
                              in document: DesignDocument) {
        renamed[new.id] = old.id
        new.id = old.id
        let sameType = old.type == new.type
        let kept = old.overrides.filter { path in
            guard ComponentProperty.named(path)?.exists(on: new) ?? false else { return false }
            return sameType || typeIndependent.contains(String(path.prefix { $0 != "." }))
        }
        // Sorted, a whole object ("text") is copied before its fields ("text.content").
        for path in kept.sorted() { ComponentProperty.named(path)!.copy(from: old, to: &new) }
        new.overrides = kept
        var unpaired = Dictionary(grouping: old.children, by: \.name)
        for index in new.children.indices {
            let name = new.children[index].name
            guard let match = unpaired[name]?.first else { continue }
            unpaired[name]!.removeFirst()
            if pairs(match, new.children[index], in: document) {
                carry(match, onto: &new.children[index], renamed: &renamed, in: document)
            }
        }
    }

    /// The override paths (with their fields) every layer type takes; the others (layout, text, effects, …) are bound to the
    /// type and are dropped when a switch pairs layers of different types.
    private static let typeIndependent: Set<String> = [
        "name", "visible", "locked", "opacity", "x", "y", "width", "height", "fill", "stroke", "sizing", "interaction", "states",
        "animation",
    ]

    /// Whether same-named layers at the same position pair up: neither is an instance, or both are instances of the same main
    /// component or of variants of the same component set.
    private static func pairs(_ old: DesignNode, _ new: DesignNode, in document: DesignDocument) -> Bool {
        switch (old.instance, new.instance) {
        case (nil, nil): return true
        case let (a?, b?):
            if a == b { return true }
            guard let set = set(of: a, in: document) else { return false }
            return set == self.set(of: b, in: document)
        default: return false
        }
    }

    /// The component set `variant` belongs to; nil when it is not a variant.
    public static func set(of variant: String, in document: DesignDocument) -> String? {
        guard let path = document.indexPath(of: variant), path.count > 1, document[path].variant != nil else { return nil }
        let parent = document[Array(path.dropLast())]
        return parent.componentSet != nil ? parent.id : nil
    }

    /// `base` when `among` lacks it, otherwise the first of "base 2", "base 3", … that it lacks.
    public static func uniqueValue(_ base: String, among used: Set<String>) -> String {
        if !used.contains(base) { return base }
        var number = 2
        while used.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Inserts `copy`, a main component whose ids `document` lacks, into component set `setID` as a variant: just after the
    /// variant `after` (the last one when nil) and `padding` below it, or `padding` inside the set's corner when the set is
    /// empty. It takes `values` for the set's properties (the localized *Default* for missing ones), with the first property's
    /// value (or `fallback`) made unique among the set's, and the set grows to include it. Returns the copy's id.
    static func insertVariant(_ copy: DesignNode, values: [String: String], fallback: String, into setID: String, after: String?,
                              in document: inout DesignDocument) throws -> String {
        let set = document.node(setID)!
        guard let first = set.componentSet?.first else { throw DesignError("Component set \(setID) has no variant properties") }
        let index = after.flatMap { id in set.children.firstIndex { $0.id == id } } ?? set.children.count - 1
        var variant = copy
        if index >= 0 {
            let above = set.children[index]
            variant.x = above.x
            variant.y = above.y + above.height + padding
        } else {
            variant.x = padding
            variant.y = padding
        }
        var next: [String: String] = [:]
        for name in set.componentSet! { next[name] = values[name].flatMap { $0.isEmpty ? nil : $0 } ?? L("Default") }
        var base = values[first].flatMap { $0.isEmpty ? nil : $0 } ?? (fallback.isEmpty ? copy.type.title : fallback)
        let used = Set(set.children.compactMap { $0.variant?[first] })
        // A copy of "Hover 2" is "Hover 3", not "Hover 2 2", when "Hover" is one of the values.
        if let space = base.lastIndex(of: " "), Int(base[base.index(after: space)...]) != nil, used.contains(String(base[..<space])) {
            base = String(base[..<space])
        }
        next[first] = uniqueValue(base, among: used)
        variant.variant = next
        variant.component = true
        try document.insert(variant, parent: setID, index: index + 1, intoSet: true)
        try document.update(setID) { set in
            set.width = max(set.width, variant.x + variant.width + padding)
            set.height = max(set.height, variant.y + variant.height + padding)
        }
        return variant.id
    }

    /// Copies of `nodes` and their layers with ids `existing` lacks (added to it). Toggle targets inside them, and instances in
    /// them of main components among them, follow the copies.
    static func freshCopies(_ nodes: [DesignNode], existing: inout Set<String>) -> [DesignNode] {
        var renamed: [String: String] = [:]
        DesignDocument(nodes: nodes).forEach { layer in
            let id = DesignDocument.newID(existing: existing)
            existing.insert(id)
            renamed[layer.id] = id
        }
        func copy(_ layer: DesignNode) -> DesignNode {
            var next = layer
            next.id = renamed[layer.id]!
            next.instance = layer.instance.map { renamed[$0] ?? $0 }
            next.source = layer.source.map { renamed[$0] ?? $0 }
            if case .toggleVisibility(let targets) = layer.interaction {
                next.interaction = .toggleVisibility(targets: targets.map { renamed[$0] ?? $0 })
            }
            next.children = layer.children.map(copy)
            return next
        }
        return nodes.map(copy)
    }
}
