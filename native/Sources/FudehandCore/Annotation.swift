import Foundation

/// Who wrote an annotation or a reply.
public enum AnnotationAuthor: String, Sendable, CaseIterable {
    case person, agent
}

/// A reply in an annotation's thread.
public struct AnnotationReply: Equatable, Sendable, Identifiable {
    public var id: String
    public var author: AnnotationAuthor
    public var text: String
    public init(id: String, author: AnnotationAuthor, text: String) { self.id = id; self.author = author; self.text = text }
}

/// A plain-text note pinned to a point inside a layer, with its replies. It is not a layer: it is drawn above the canvas,
/// never in the layers panel or in snapshots. `x` and `y` are relative to the layer's top-left corner, so the annotation follows
/// the layer when it moves; the canvas keeps the marker inside the layer when the layer shrinks (ADR 0011).
public struct DesignAnnotation: Equatable, Sendable, Identifiable {
    public var id: String
    /// The id of the layer it is pinned to.
    public var node: String
    public var x: Double
    public var y: Double
    public var author: AnnotationAuthor
    public var text: String
    public var replies: [AnnotationReply] = []

    public init(id: String, node: String, x: Double, y: Double, author: AnnotationAuthor, text: String, replies: [AnnotationReply] = []) {
        self.id = id; self.node = node; self.x = x; self.y = y; self.author = author; self.text = text; self.replies = replies
    }

    /// The point the marker sits at, in canvas coordinates, for the layer's absolute rectangle: kept inside the layer.
    public func anchor(in rect: Rect) -> Point {
        Point(x: rect.x + min(max(x, 0), rect.width), y: rect.y + min(max(y, 0), rect.height))
    }

    /// The number of messages in the thread: the annotation and its replies.
    public var count: Int { 1 + replies.count }
}

// MARK: JSON

extension DesignAnnotation {
    static let keys: Set<String> = ["id", "node", "x", "y", "author", "text", "replies"]
    static let replyKeys: Set<String> = ["id", "author", "text"]

    /// Builds and validates an annotation read from a project file.
    public static func from(_ value: Any) throws -> DesignAnnotation {
        guard let object = value as? [String: Any] else { throw DesignError("Annotation must be a JSON object") }
        let id = try field(object, "id", in: "Annotation")
        let owner = "Annotation \(id)"
        if let unknown = object.keys.filter({ !keys.contains($0) }).sorted().first { throw DesignError("\(owner): unsupported field \(unknown)") }
        var annotation = DesignAnnotation(id: id, node: try field(object, "node", in: owner), x: try coordinate(object, "x", in: owner),
                                          y: try coordinate(object, "y", in: owner), author: try author(object, in: owner),
                                          text: try validText(object["text"], field: "text", in: owner))
        switch object["replies"] {
        case nil, is NSNull: break
        case let list as [Any]:
            annotation.replies = try list.map { item in
                guard let reply = item as? [String: Any] else { throw DesignError("\(owner): each reply must be a JSON object") }
                if let unknown = reply.keys.filter({ !replyKeys.contains($0) }).sorted().first {
                    throw DesignError("\(owner): unsupported reply field \(unknown)")
                }
                return AnnotationReply(id: try field(reply, "id", in: owner), author: try author(reply, in: owner),
                                       text: try validText(reply["text"], field: "text", in: owner))
            }
        default: throw DesignError("\(owner): replies must be an array")
        }
        return annotation
    }

    public var object: [String: Any] {
        ["id": id, "node": node, "x": x, "y": y, "author": author.rawValue, "text": text,
         "replies": replies.map { ["id": $0.id, "author": $0.author.rawValue, "text": $0.text] }]
    }

    /// The text of an annotation or reply: a non-empty string once surrounding white space is trimmed, stored trimmed.
    public static func validText(_ value: Any?, field: String = "text", in owner: String? = nil) throws -> String {
        let prefix = owner.map { "\($0): " } ?? ""
        guard let raw = value, !(raw is NSNull) else { throw DesignError("\(prefix)missing \(field)") }
        guard let text = raw as? String else { throw DesignError("\(prefix)\(field) must be a string") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DesignError("\(prefix)\(field) must not be empty") }
        return trimmed
    }

    private static func field(_ object: [String: Any], _ key: String, in owner: String) throws -> String {
        guard let raw = object[key], !(raw is NSNull) else { throw DesignError("\(owner) is missing \(key)") }
        guard let text = raw as? String, !text.isEmpty else { throw DesignError("\(owner): \(key) must be a non-empty string") }
        return text
    }

    private static func coordinate(_ object: [String: Any], _ key: String, in owner: String) throws -> Double {
        guard let raw = object[key], !(raw is NSNull) else { throw DesignError("\(owner) is missing \(key)") }
        guard let number = raw as? NSNumber, !DesignJSON.isBool(number), number.doubleValue.isFinite,
              (0...DesignJSON.maximumMagnitude).contains(number.doubleValue) else {
            throw DesignError("\(owner): \(key) must be a number from 0 to 1000000")
        }
        return number.doubleValue
    }

    private static func author(_ object: [String: Any], in owner: String) throws -> AnnotationAuthor {
        guard let raw = object["author"], !(raw is NSNull) else { return .person }
        guard let name = raw as? String, let author = AnnotationAuthor(rawValue: name) else {
            throw DesignError("\(owner): author must be one of \(AnnotationAuthor.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return author
    }
}

// MARK: Document operations

extension DesignDocument {
    /// The annotation with this id, or the annotation whose thread holds a reply with this id.
    public func annotation(containing id: String) -> DesignAnnotation? {
        annotations.first { $0.id == id || $0.replies.contains { $0.id == id } }
    }

    /// The annotations pinned to a layer, in the order they were added.
    public func annotations(on node: String) -> [DesignAnnotation] { annotations.filter { $0.node == node } }

    private var annotationIDs: Set<String> {
        Set(annotations.flatMap { [$0.id] + $0.replies.map(\.id) })
    }

    /// Pins a new annotation to a point inside a layer; `x` and `y` are relative to the layer's top-left corner and kept inside it.
    @discardableResult
    public mutating func addAnnotation(on node: String, x: Double, y: Double, text: String, author: AnnotationAuthor) throws -> DesignAnnotation {
        guard let layer = self.node(node) else { throw DesignError("Layer not found: \(node)") }
        guard x.isFinite, y.isFinite else { throw DesignError("x and y must be numbers") }
        let annotation = DesignAnnotation(id: Self.newID(existing: annotationIDs.union(allIDs())), node: node,
                                          x: min(max(x, 0), layer.width), y: min(max(y, 0), layer.height),
                                          author: author, text: try DesignAnnotation.validText(text))
        annotations.append(annotation)
        return annotation
    }

    /// Adds a reply to the end of an annotation's thread. `id` may also be a reply in that thread.
    @discardableResult
    public mutating func replyToAnnotation(_ id: String, text: String, author: AnnotationAuthor) throws -> AnnotationReply {
        guard let index = annotations.firstIndex(where: { $0.id == id || $0.replies.contains { $0.id == id } }) else {
            throw DesignError("Annotation not found: \(id)")
        }
        let reply = AnnotationReply(id: Self.newID(existing: annotationIDs.union(allIDs())), author: author,
                                    text: try DesignAnnotation.validText(text))
        annotations[index].replies.append(reply)
        return reply
    }

    /// Replaces the text of an annotation or a reply.
    public mutating func updateAnnotation(_ id: String, text: String) throws {
        let text = try DesignAnnotation.validText(text)
        for index in annotations.indices {
            if annotations[index].id == id { annotations[index].text = text; return }
            if let reply = annotations[index].replies.firstIndex(where: { $0.id == id }) { annotations[index].replies[reply].text = text; return }
        }
        throw DesignError("Annotation not found: \(id)")
    }

    /// Deletes an annotation with its whole thread, or a single reply.
    public mutating func deleteAnnotation(_ id: String) throws {
        for index in annotations.indices {
            if annotations[index].id == id { annotations.remove(at: index); return }
            if let reply = annotations[index].replies.firstIndex(where: { $0.id == id }) { annotations[index].replies.remove(at: reply); return }
        }
        throw DesignError("Annotation not found: \(id)")
    }

    /// Drops the annotations whose layer no longer exists: deleting a layer deletes the annotations on it and on its
    /// descendants in the same undo step. The editor calls this after every edit.
    public mutating func pruneAnnotations() {
        guard !annotations.isEmpty else { return }
        let ids = allIDs()
        annotations.removeAll { !ids.contains($0.node) }
    }

    func validateAnnotations() throws {
        let layers = allIDs()
        var seen = Set<String>()
        for annotation in annotations {
            guard layers.contains(annotation.node) else { throw DesignError("Annotation \(annotation.id) is pinned to a missing layer: \(annotation.node)") }
            for id in [annotation.id] + annotation.replies.map(\.id) where !seen.insert(id).inserted {
                throw DesignError("Duplicate annotation id: \(id)")
            }
        }
    }
}

// MARK: Markers

extension DesignIndex {
    /// The annotations to draw on the canvas with their anchors in canvas coordinates, in the order added (later ones on top).
    /// An annotation is hidden while its layer or one of the layer's ancestors is hidden.
    public func annotationMarkers() -> [(annotation: DesignAnnotation, anchor: Point)] {
        document.annotations.compactMap { annotation in
            guard let rect = worldRect(annotation.node),
                  ancestry(of: annotation.node).allSatisfy({ node($0)?.visible ?? false }) else { return nil }
            return (annotation, annotation.anchor(in: rect))
        }
    }
}
