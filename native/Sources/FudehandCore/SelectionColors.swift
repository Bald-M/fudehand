import Foundation

/// Selection colors: every color the selected layers and all their child layers use — fill, stroke, text color, and icon
/// color — counted once per use and merged by hex value, so one color can be read and replaced across the selection.
public struct SelectionColor: Equatable, Sendable {
    public var color: DesignColor
    /// How many properties use the color.
    public var count: Int
    public init(color: DesignColor, count: Int) { self.color = color; self.count = count }
}

/// The layer properties that hold a selection color.
public enum ColorProperty: String, Sendable, CaseIterable { case fill, stroke, text, icon }

/// One property of one layer that uses a color.
public struct ColorUse: Hashable, Sendable {
    public var id: String
    public var property: ColorProperty
    public init(id: String, property: ColorProperty) { self.id = id; self.property = property }
}

public enum SelectionColors {
    /// The colors used under `ids`, most used first (ties keep the order they are first met in, depth first through the
    /// document). A layer selected together with one of its ancestors is counted once. Unknown ids are ignored.
    public static func collect(_ ids: Set<String>, in document: DesignDocument) -> [SelectionColor] {
        collect(roots(ids, in: document))
    }

    /// `collect(_:in:)` that finds the selected layers through `index` instead of searching the whole tree, for panels that
    /// update on every selection change (#227).
    public static func collect(_ ids: Set<String>, in index: DesignIndex) -> [SelectionColor] {
        collect(roots(ids, in: index))
    }

    private static func collect(_ roots: [DesignNode]) -> [SelectionColor] {
        var result: [SelectionColor] = []
        var position: [UInt32: Int] = [:]
        visit(roots) { _, _, color in
            let key = self.key(color)
            if let index = position[key] { result[index].count += 1 } else {
                position[key] = result.count
                result.append(SelectionColor(color: color, count: 1))
            }
        }
        // `sorted` is not stable; the first-met position breaks ties.
        return result.enumerated().sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }.map(\.element)
    }

    /// The properties under `ids` that use `color` (matched by hex value), depth first.
    public static func uses(of color: DesignColor, under ids: Set<String>, in document: DesignDocument) -> [ColorUse] {
        let key = self.key(color)
        var result: [ColorUse] = []
        visit(roots(ids, in: document)) { node, property, value in
            if self.key(value) == key { result.append(ColorUse(id: node.id, property: property)) }
        }
        return result
    }

    /// The color a use holds now; nil when its layer is gone or no longer has that property.
    public static func color(of use: ColorUse, in document: DesignDocument) -> DesignColor? {
        document.node(use.id).flatMap { color(use.property, of: $0) }
    }

    /// `color(of:in:)` that finds the layer through `index`.
    public static func color(of use: ColorUse, in index: DesignIndex) -> DesignColor? {
        index.node(use.id).flatMap { color(use.property, of: $0) }
    }

    /// Sets `color` on each of `uses` in one pass over the document, and returns how many properties changed. Uses whose
    /// layer is gone or no longer has the property are skipped.
    @discardableResult
    public static func set(_ color: DesignColor, at uses: [ColorUse], in document: inout DesignDocument) -> Int {
        var pending = Dictionary(grouping: uses, by: \.id).mapValues { Set($0.map(\.property)) }
        var changed = 0
        func apply(_ nodes: inout [DesignNode]) {
            for index in nodes.indices where !pending.isEmpty {
                if let properties = pending.removeValue(forKey: nodes[index].id) {
                    for property in properties { if set(color, property, of: &nodes[index]) { changed += 1 } }
                }
                apply(&nodes[index].children)
            }
        }
        apply(&document.nodes)
        return changed
    }

    private static func color(_ property: ColorProperty, of node: DesignNode) -> DesignColor? {
        switch property {
        case .fill: return node.fill
        case .stroke: return node.stroke?.color
        case .text: return node.text?.color
        case .icon: return node.icon?.color
        }
    }

    /// Whether the color changed.
    private static func set(_ color: DesignColor, _ property: ColorProperty, of node: inout DesignNode) -> Bool {
        guard let old = self.color(property, of: node), old != color else { return false }
        switch property {
        case .fill: node.fill = color
        case .stroke: node.stroke?.color = color
        case .text: node.text?.color = color
        case .icon: node.icon?.color = color
        }
        return true
    }

    /// The color's hex value as its four rounded bytes: equal exactly when the hex values are, without formatting a string for
    /// every use (#227).
    private static func key(_ color: DesignColor) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(color.r) << 24 | byte(color.g) << 16 | byte(color.b) << 8 | byte(color.a)
    }

    /// The outermost selected layers, depth first: a layer under another selected id is left out, so it is visited once.
    private static func roots(_ ids: Set<String>, in document: DesignDocument) -> [DesignNode] {
        var result: [DesignNode] = []
        func search(_ nodes: [DesignNode]) {
            for node in nodes { if ids.contains(node.id) { result.append(node) } else { search(node.children) } }
        }
        search(document.nodes)
        return result
    }

    /// `roots(_:in:)` through the index: unknown ids and ids under another selected id are dropped, and the rest are put in
    /// depth-first order by index path.
    private static func roots(_ ids: Set<String>, in index: DesignIndex) -> [DesignNode] {
        ids.compactMap { id -> (path: [Int], id: String)? in
            guard !index.ancestry(of: id).dropLast().contains(where: ids.contains), let path = index.indexPath(of: id) else { return nil }
            return (path, id)
        }
        .sorted { $0.path.lexicographicallyPrecedes($1.path) }
        .compactMap { index.node($0.id) }
    }

    /// Calls `body` for each color property of `roots` and all their children, depth first.
    private static func visit(_ roots: [DesignNode], _ body: (DesignNode, ColorProperty, DesignColor) -> Void) {
        func each(_ node: DesignNode) {
            for property in ColorProperty.allCases { if let value = color(property, of: node) { body(node, property, value) } }
            node.children.forEach(each)
        }
        roots.forEach(each)
    }
}
