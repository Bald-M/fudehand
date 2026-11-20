import Foundation
import Testing

/// An icon-only button or menu in the App's SwiftUI sources: a `Button(action:) { Image(…) }` or `label: { Image(…) }`
/// whose label shows nothing but an image.
private struct IconButton {
    let file: String
    let line: Int
    /// The label closure and the modifier chain that follows it.
    let label: String
    let modifiers: String
}

/// Returns the UTF-16 offset just past the brace that closes the one at `open`.
private func closingBrace(_ text: NSString, from open: Int) -> Int? {
    var depth = 0
    for i in open..<text.length {
        switch text.character(at: i) {
        case 0x7B: depth += 1
        case 0x7D: depth -= 1; if depth == 0 { return i + 1 }
        default: break
        }
    }
    return nil
}

private func iconButtons() throws -> [IconButton] {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/FudehandApp")
    let opener = try NSRegularExpression(pattern: #"(\blabel:\s*|\bButton\(action:[^)]*\)\s*)\{"#)
    var found: [IconButton] = []
    for case let url as URL in FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        let ns = source as NSString
        for match in opener.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let open = match.range.location + match.range.length - 1
            guard let end = closingBrace(ns, from: open) else { continue }
            let label = ns.substring(with: NSRange(location: open + 1, length: end - open - 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.hasPrefix("Image("), !label.contains("Text("), !label.contains("Label(") else { continue }
            // The modifier chain: the rest of the closing line and every following line that starts with a modifier.
            var lines = ns.substring(from: end).components(separatedBy: "\n")
            var modifiers = lines.removeFirst()
            for line in lines {
                guard line.trimmingCharacters(in: .whitespaces).hasPrefix(".") else { break }
                modifiers += "\n" + line
            }
            let line = ns.substring(to: open).components(separatedBy: "\n").count
            found.append(IconButton(file: url.lastPathComponent, line: line, label: label, modifiers: modifiers))
        }
    }
    return found
}

/// VoiceOver reads an icon-only button by its symbol name ("xmark") unless it has a label (#174).
@Test func everyIconOnlyButtonHasAnAccessibilityLabel() throws {
    let buttons = try iconButtons()
    #expect(buttons.count > 20)
    for button in buttons {
        #expect((button.label + button.modifiers).contains(".accessibilityLabel("), "\(button.file):\(button.line) has no accessibilityLabel")
    }
}

/// Icon-only buttons are at least 16×16 points to click (#174): `iconHitTarget()` or an explicit frame on the label. Menus
/// (`.menuStyle`) are drawn by AppKit at its own size, which a SwiftUI frame does not change, and toolbar items
/// (`WorkspaceView`) are sized by the system, so neither is checked here.
@Test func everyIconOnlyButtonHasAClickTargetOfAtLeastSixteenPoints() throws {
    let frame = try NSRegularExpression(pattern: #"\.frame\(width: (\d+), height: (\d+)\)"#)
    func framed(_ text: String) -> Bool {
        let ns = text as NSString
        return frame.matches(in: text, range: NSRange(location: 0, length: ns.length)).contains { match in
            Int(ns.substring(with: match.range(at: 1)))! >= 16 && Int(ns.substring(with: match.range(at: 2)))! >= 16
        }
    }
    for button in try iconButtons() where button.file != "WorkspaceView.swift" && !button.modifiers.contains(".menuStyle(") {
        let sized = button.label.contains(".iconHitTarget()") || framed(button.label)
        #expect(sized, "\(button.file):\(button.line) has a click target under 16×16")
    }
}
