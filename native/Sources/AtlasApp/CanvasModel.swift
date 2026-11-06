import AtlasCore
import Combine

/// A one-off command from the store to the canvas; a new `token` means "apply this once".
struct ViewportRequest: Equatable {
    var viewport: Viewport
    var animated: Bool
    var token: Int
}

/// Carries the live viewport from the canvas to the toolbar without re-rendering SwiftUI on every tick.
@MainActor
final class ZoomIndicator: ObservableObject {
    @Published private(set) var scale = 1.0
    /// The live viewport; deliberately not published.
    private(set) var viewport = Viewport()

    func update(_ viewport: Viewport) {
        self.viewport = viewport
        if abs(viewport.scale - scale) >= 0.005 * scale { scale = viewport.scale }
    }
}
