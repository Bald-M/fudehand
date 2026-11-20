import SwiftUI

extension View {
    /// Gives an icon-only button's label a click target of at least 20×20 points, however small the glyph (#174).
    /// See "Accessibility" in `docs/accessibility.md`.
    func iconHitTarget() -> some View {
        frame(minWidth: 20, minHeight: 20).contentShape(Rectangle())
    }
}
