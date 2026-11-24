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
        /// The matched field's whole text and the query, kept so the excerpt is only cut when it is read: a query such as "e"
        /// can match every layer of a large document, and the find bar never shows excerpts.
        fileprivate var source: String
        fileprivate var query: String
        /// The matched field on one line, cut to about 80 characters around the hit.
        public var excerpt: String { DesignFind.excerpt(source, query) }
    }

    /// Every layer, hidden and locked ones included, whose text content or name contains the trimmed query, ignoring case and
    /// accents, in depth-first layer-tree order. A blank query matches nothing.
    public static func matches(in document: DesignDocument, query: String) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let needle = Needle(query)
        var matches: [Match] = []
        func visit(_ nodes: [DesignNode]) {
            for node in nodes {
                if let content = node.text?.content, needle.found(in: content) {
                    matches.append(Match(id: node.id, name: node.name, type: node.type, field: .text, source: content, query: query))
                } else if needle.found(in: node.name) {
                    matches.append(Match(id: node.id, name: node.name, type: node.type, field: .name, source: node.name, query: query))
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

    /// The query, prepared once. Foundation's case- and accent-insensitive search costs about 15 ms over the 16,000 layers of
    /// the benchmark document, so text that folds only in its ASCII letters is compared byte by byte, lowercasing those letters.
    /// That covers ASCII and CJK text with its punctuation. Text with two-byte UTF-8 characters (accented Latin, Greek,
    /// Cyrillic, combining accents) or characters from U+1000–U+1FFF (more accented Latin and Greek) is folded by Foundation.
    /// Cased letters elsewhere, such as fullwidth Latin, match only in the case typed.
    private struct Needle {
        let bytes: [UInt8]?
        let folded: String

        init(_ query: String) {
            bytes = Needle.foldsAsASCII(query.utf8) ? query.utf8.map(Needle.lower) : nil
            folded = query.folding(options: options, locale: nil)
        }

        func found(in field: String) -> Bool {
            if let bytes, let found = field.utf8.withContiguousStorageIfAvailable({ Needle.search(bytes, in: $0) }) ?? nil {
                return found
            }
            return field.folding(options: options, locale: nil).contains(folded)
        }

        private static func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }

        /// No lead byte of a two-byte character (0xC0–0xDF) or of a U+1000–U+1FFF character (0xE1).
        private static func foldsAsASCII<Bytes: Sequence>(_ utf8: Bytes) -> Bool where Bytes.Element == UInt8 {
            utf8.allSatisfy { $0 < 0xC0 || ($0 > 0xDF && $0 != 0xE1) }
        }

        /// Whether `needle` occurs in `bytes` ignoring ASCII case, or nil when `bytes` needs Foundation's folding.
        private static func search(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Bool? {
            guard foldsAsASCII(bytes) else { return nil }
            guard needle.count <= bytes.count else { return false }
            return (0...(bytes.count - needle.count)).contains { start in
                needle.indices.allSatisfy { lower(bytes[start + $0]) == needle[$0] }
            }
        }
    }

    fileprivate static func excerpt(_ field: String, _ query: String) -> String {
        let hit = field.range(of: query, options: options) ?? field.startIndex..<field.startIndex
        let flat = { (text: Substring) in text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") }
        guard field.count > excerptLength else { return flat(field[...]) }
        let start = field.index(hit.lowerBound, offsetBy: -leadingContext, limitedBy: field.startIndex) ?? field.startIndex
        let end = field.index(start, offsetBy: excerptLength, limitedBy: field.endIndex) ?? field.endIndex
        return (start == field.startIndex ? "" : "…") + flat(field[start..<end]) + (end == field.endIndex ? "" : "…")
    }
}
