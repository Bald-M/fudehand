import AppKit
import SwiftUI

extension View {
    /// Gives an icon-only button's label a click target of at least 20×20 points, however small the glyph (#174).
    /// See "Accessibility" in `docs/accessibility.md`.
    func iconHitTarget() -> some View {
        frame(minWidth: 20, minHeight: 20).contentShape(Rectangle())
    }
}

/// The label of an icon-only `.borderlessButton` menu. AppKit draws such a menu at the height of its label image and
/// ignores SwiftUI frames, padding, fonts, and control sizes, so the symbol is drawn at its usual size in the middle of a
/// transparent `side`×`side` template image (#174).
struct MenuIcon: View {
    let symbol: String
    let label: String
    var side: CGFloat = 20

    var body: some View {
        Image(nsImage: Self.image(symbol, label: label, side: side))
    }

    static func image(_ symbol: String, label: String, side: CGFloat = 20) -> NSImage {
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { return NSImage() }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let size = glyph.size
            glyph.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}
