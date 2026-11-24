import Foundation

/// Find (⌘F): the layers whose text content or name contains a query. The find bar and the `find_nodes` control command share
/// these rules (#257).
public enum DesignFind {
    /// Where a layer matched. A text layer whose content matches is a text match even when its name matches too.
    public enum Field: String, Sendable { case text, name }

    public struct Match: Equatable, Sendable {
        public var id: String
        public var name: String
        public var type: NodeType
        public var field: Field
        /// The matched field on one line, cut to about 80 characters around the hit.
        public var excerpt: String
    }

    /// Every layer, hidden and locked ones included, whose text content or name contains the trimmed query, ignoring case and
    /// accents, in depth-first layer-tree order. A blank query matches nothing.
    public static func matches(in document: DesignDocument, query: String) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var matches: [Match] = []
        func visit(_ nodes: [DesignNode]) {
            for node in nodes {
                if let content = node.text?.content, let hit = content.range(of: query, options: options) {
                    matches.append(Match(id: node.id, name: node.name, type: node.type, field: .text, excerpt: excerpt(content, hit)))
                } else if let hit = node.name.range(of: query, options: options) {
                    matches.append(Match(id: node.id, name: node.name, type: node.type, field: .name, excerpt: excerpt(node.name, hit)))
                }
                visit(node.children)
            }
        }
        visit(document.nodes)
        return matches
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private static let excerptLength = 80
    private static let leadingContext = 30

    private static func excerpt(_ field: String, _ hit: Range<String.Index>) -> String {
        let flat = { (text: Substring) in text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") }
        guard field.count > excerptLength else { return flat(field[...]) }
        let start = field.index(hit.lowerBound, offsetBy: -leadingContext, limitedBy: field.startIndex) ?? field.startIndex
        let end = field.index(start, offsetBy: excerptLength, limitedBy: field.endIndex) ?? field.endIndex
        return (start == field.startIndex ? "" : "…") + flat(field[start..<end]) + (end == field.endIndex ? "" : "…")
    }
}
