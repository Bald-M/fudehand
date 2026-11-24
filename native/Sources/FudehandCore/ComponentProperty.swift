import Foundation

/// One overridable property of a layer, addressed by the JSON path an `overrides` entry uses (`fill`, `text.content`, …).
/// Comparing and copying work on Swift values through key paths, so they stay cheap when run every frame of a drag.
public struct ComponentProperty: Sendable {
    /// The JSON path: a top-level key, or `key.field` for a field of a nested object.
    public let path: String
    /// Set on the whole-object path of a nested object (`text`) and on its field paths (`text.content`): the nested key.
    private let group: String?
    private let isWholeObject: Bool
    private let isPresent: @Sendable (DesignNode) -> Bool
    private let isEqual: @Sendable (DesignNode, DesignNode) -> Bool
    private let assign: @Sendable (DesignNode, inout DesignNode) -> Void

    public func equal(_ a: DesignNode, _ b: DesignNode) -> Bool { isEqual(a, b) }
    public func copy(from source: DesignNode, to target: inout DesignNode) { assign(source, &target) }
    /// False for a field of a nested object that `node` lacks (`text.content` on a layer without text); true otherwise.
    public func exists(on node: DesignNode) -> Bool { isWholeObject || isPresent(node) }

    /// Every overridable property: the paths of `DesignJSON.nodeKeys` except `id`, `type`, `children`, and the component keys,
    /// with each nested object split into one path per field plus a whole-object path.
    public static let all: [ComponentProperty] = table
    private static let byPath = Dictionary(uniqueKeysWithValues: table.map { ($0.path, $0) })

    public static func named(_ path: String) -> ComponentProperty? { byPath[path] }

    /// Paths whose values differ between `a` and `b`. A nested object that is missing on one side only is reported whole,
    /// otherwise field by field.
    public static func changed(_ a: DesignNode, _ b: DesignNode) -> Set<String> {
        var result: Set<String> = []
        for property in table {
            if let group = property.group {
                let bothPresent = property.isPresent(a) && property.isPresent(b)
                if property.isWholeObject {
                    if property.isPresent(a) != property.isPresent(b) { result.insert(group) }
                } else if bothPresent, !property.isEqual(a, b) {
                    result.insert(property.path)
                }
            } else if !property.isEqual(a, b) {
                result.insert(property.path)
            }
        }
        return result
    }

    // MARK: Table

    private typealias Path<Root, Value> = WritableKeyPath<Root, Value> & Sendable

    private static func plain<V: Equatable>(_ key: String, _ keyPath: Path<DesignNode, V>) -> ComponentProperty {
        ComponentProperty(path: key, group: nil, isWholeObject: false, isPresent: { _ in true },
                          isEqual: { $0[keyPath: keyPath] == $1[keyPath: keyPath] },
                          assign: { $1[keyPath: keyPath] = $0[keyPath: keyPath] })
    }

    /// A nested object that may be absent: the whole-object path, then one path per field.
    private static func optionalObject<O: Equatable>(_ key: String, _ object: Path<DesignNode, O?>,
                                                     fields: [ComponentProperty]) -> [ComponentProperty] {
        let whole = ComponentProperty(path: key, group: key, isWholeObject: true, isPresent: { $0[keyPath: object] != nil },
                                      isEqual: { $0[keyPath: object] == $1[keyPath: object] },
                                      assign: { $1[keyPath: object] = $0[keyPath: object] })
        return [whole] + fields
    }

    private static func optionalField<O, V: Equatable>(_ key: String, _ field: String, _ object: Path<DesignNode, O?>,
                                                       _ inner: Path<O, V>) -> ComponentProperty {
        ComponentProperty(path: "\(key).\(field)", group: key, isWholeObject: false, isPresent: { $0[keyPath: object] != nil },
                          isEqual: { a, b in
                              switch (a[keyPath: object], b[keyPath: object]) {
                              case (nil, nil): return true
                              case let (x?, y?): return x[keyPath: inner] == y[keyPath: inner]
                              default: return false
                              }
                          },
                          assign: { source, target in
                              guard let value = source[keyPath: object] else { target[keyPath: object] = nil; return }
                              if target[keyPath: object] == nil { target[keyPath: object] = value } else {
                                  target[keyPath: object]?[keyPath: inner] = value[keyPath: inner]
                              }
                          })
    }

    private static func solidObject<O: Equatable>(_ key: String, _ object: Path<DesignNode, O>,
                                                  fields: [ComponentProperty]) -> [ComponentProperty] {
        [plain(key, object).inGroup(key, whole: true)] + fields
    }

    private static func solidField<O, V: Equatable>(_ key: String, _ field: String, _ object: Path<DesignNode, O>,
                                                    _ inner: Path<O, V>) -> ComponentProperty {
        ComponentProperty(path: "\(key).\(field)", group: key, isWholeObject: false, isPresent: { _ in true },
                          isEqual: { $0[keyPath: object][keyPath: inner] == $1[keyPath: object][keyPath: inner] },
                          assign: { $1[keyPath: object][keyPath: inner] = $0[keyPath: object][keyPath: inner] })
    }

    private func inGroup(_ key: String, whole: Bool) -> ComponentProperty {
        ComponentProperty(path: path, group: key, isWholeObject: whole, isPresent: isPresent, isEqual: isEqual, assign: assign)
    }

    private static let table: [ComponentProperty] = {
        func text<V: Equatable>(_ field: String, _ inner: Path<DesignText, V>) -> ComponentProperty {
            optionalField("text", field, \DesignNode.text, inner)
        }
        var table: [ComponentProperty] = [
            plain("name", \DesignNode.name), plain("x", \DesignNode.x), plain("y", \DesignNode.y),
            plain("width", \DesignNode.width), plain("height", \DesignNode.height), plain("visible", \DesignNode.visible),
            plain("locked", \DesignNode.locked), plain("opacity", \DesignNode.opacity), plain("fill", \DesignNode.fill),
            plain("cornerRadius", \DesignNode.cornerRadius), plain("clipsContent", \DesignNode.clipsContent),
            plain("interaction", \DesignNode.interaction), plain("scroll", \DesignNode.scroll),
            plain("fixedOnScroll", \DesignNode.fixedOnScroll), plain("states", \DesignNode.states),
            plain("animation", \DesignNode.animation), plain("effects", \DesignNode.effects),
            plain("layoutGuides", \DesignNode.layoutGuides),
        ]
        table += optionalObject("stroke", \DesignNode.stroke, fields: [
            optionalField("stroke", "color", \DesignNode.stroke, \DesignStroke.color),
            optionalField("stroke", "width", \DesignNode.stroke, \DesignStroke.width),
        ])
        table += solidObject("sizing", \DesignNode.sizing, fields: [
            solidField("sizing", "horizontal", \DesignNode.sizing, \Sizing.horizontal),
            solidField("sizing", "vertical", \DesignNode.sizing, \Sizing.vertical),
        ])
        table += optionalObject("text", \DesignNode.text, fields: [
            text("content", \DesignText.content), text("fontSize", \DesignText.fontSize), text("fontWeight", \DesignText.fontWeight),
            text("fontFamily", \DesignText.fontFamily), text("color", \DesignText.color), text("align", \DesignText.align),
            text("lineHeight", \DesignText.lineHeight), text("autoResize", \DesignText.autoResize),
            text("sequence", \DesignText.sequence),
        ])
        table += optionalObject("image", \DesignNode.image, fields: [
            optionalField("image", "data", \DesignNode.image, \DesignImage.data),
            optionalField("image", "fit", \DesignNode.image, \DesignImage.fit),
        ])
        table += optionalObject("icon", \DesignNode.icon, fields: [
            optionalField("icon", "name", \DesignNode.icon, \DesignIcon.name),
            optionalField("icon", "color", \DesignNode.icon, \DesignIcon.color),
        ])
        table += optionalObject("layout", \DesignNode.layout, fields: [
            optionalField("layout", "direction", \DesignNode.layout, \AutoLayout.direction),
            optionalField("layout", "spacing", \DesignNode.layout, \AutoLayout.spacing),
            optionalField("layout", "padding", \DesignNode.layout, \AutoLayout.padding),
            optionalField("layout", "align", \DesignNode.layout, \AutoLayout.align),
            optionalField("layout", "crossAlign", \DesignNode.layout, \AutoLayout.crossAlign),
        ])
        table += optionalObject("versionSnapshot", \DesignNode.versionSnapshot, fields: [
            optionalField("versionSnapshot", "frame", \DesignNode.versionSnapshot, \VersionSnapshot.frame),
            optionalField("versionSnapshot", "createdAt", \DesignNode.versionSnapshot, \VersionSnapshot.createdAt),
            optionalField("versionSnapshot", "note", \DesignNode.versionSnapshot, \VersionSnapshot.note),
        ])
        return table
    }()
}
