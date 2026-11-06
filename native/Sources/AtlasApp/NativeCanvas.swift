import AppKit
import SwiftUI
import AtlasCore

/// The document coordinate system scales; each web view keeps its CSS viewport size.
/// The canvas owns the live viewport and selection and reports only settled values.
struct NativeCanvas: NSViewRepresentable {
    let project: Project
    let positions: [String: Point]
    let positionsToken: Int
    let viewportRequest: ViewportRequest
    let tool: CanvasTool
    let reloadToken: Int
    let zoomIndicator: ZoomIndicator
    let onViewportSettled: (Viewport) -> Void
    let onFramesMoved: ([String: Point]) -> Void
    let onSelectionChange: (Set<String>) -> Void
    let onToolChange: (CanvasTool) -> Void
    let onFocusFrame: (String) -> Void
    let onSizeChange: (CGSize) -> Void

    func makeNSView(context: Context) -> AtlasCanvasView {
        let view = AtlasCanvasView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AtlasCanvasView, context: Context) {
        view.zoomIndicator = zoomIndicator
        view.onViewportSettled = onViewportSettled
        view.onFramesMoved = onFramesMoved
        view.onSelectionChange = onSelectionChange
        view.onToolChange = onToolChange
        view.onFocusFrame = onFocusFrame
        view.onSizeChange = onSizeChange
        view.update(project: project, positions: positions, positionsToken: positionsToken,
                    viewportRequest: viewportRequest, tool: tool, reloadToken: reloadToken)
    }

    static func dismantleNSView(_ view: AtlasCanvasView, coordinator: ()) {
        view.dispose()
    }
}
