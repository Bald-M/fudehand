import Foundation

/// Splits an assistant reply into the Markdown blocks the chat panel draws. Inline styles (bold, code, links) are left in the
/// text for the view to style. Text that is still streaming in is valid input: an unclosed code fence runs to the end.
public enum ChatMarkdown {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `marker` is "•" for a bulleted item or the number with a period; `indent` is the nesting depth.
        case item(marker: String, indent: Int, text: String)
        case code(language: String, text: String)
        case quote(String)
        case rule
    }

    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var code: (language: String, lines: [String])?
        /// Whether the next plain line continues the last block instead of starting a paragraph.
        var open = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = code {
                if trimmed.hasPrefix("```") { blocks.append(.code(language: current.language, text: current.lines.joined(separator: "\n"))); code = nil }
                else { code!.lines.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") {
                code = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                open = false
            } else if trimmed.isEmpty {
                open = false
            } else if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
                open = false
            } else if trimmed.wholeMatch(of: #/(-{3,}|\*{3,}|_{3,})/#) != nil {
                blocks.append(.rule)
                open = false
            } else if let match = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                if open, case .quote(let previous) = blocks.last { blocks[blocks.count - 1] = .quote("\(previous)\n\(match.1)") }
                else { blocks.append(.quote(String(match.1))) }
                open = true
            } else if let match = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.*)$/#) {
                let marker = match.2.first!.isNumber ? "\(match.2.dropLast())." : "•"
                blocks.append(.item(marker: marker, indent: match.1.count / 2, text: String(match.3)))
                open = true
            } else if open, case .item(let marker, let indent, let previous) = blocks.last {
                blocks[blocks.count - 1] = .item(marker: marker, indent: indent, text: "\(previous)\n\(trimmed)")
            } else if open, case .paragraph(let previous) = blocks.last {
                blocks[blocks.count - 1] = .paragraph("\(previous)\n\(trimmed)")
            } else {
                blocks.append(.paragraph(trimmed))
                open = true
            }
        }
        if let code { blocks.append(.code(language: code.language, text: code.lines.joined(separator: "\n"))) }
        return blocks
    }
}
