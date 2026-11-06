import AppKit
import SwiftUI
import AtlasCore

/// The document coordinate system scales; each web view keeps its CSS viewport size.
struct NativeCanvas: NSViewRepresentable {
    let project: Project
    let viewport: Viewport
    let positions: [String: Point]
    let interactingFrameID: String?
    let reloadToken: Int
    let onViewportChange: (Viewport) -> Void
    let onMoveFrame: (String, Point) -> Void
    let onInteractionChange: (String?) -> Void
    let onFocusFrame: (String) -> Void
    let onSizeChange: (CGSize) -> Void

    func makeNSView(context: Context) -> AtlasCanvasView {
        let view = AtlasCanvasView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AtlasCanvasView, context: Context) {
        view.onViewportChange = onViewportChange
        view.onMoveFrame = onMoveFrame
        view.onInteractionChange = onInteractionChange
        view.onFocusFrame = onFocusFrame
        view.onSizeChange = onSizeChange
        view.update(project: project, viewport: viewport, positions: positions,
                    interactingFrameID: interactingFrameID, reloadToken: reloadToken)
    }

    static func dismantleNSView(_ view: AtlasCanvasView, coordinator: ()) {
        view.dispose()
    }
}
