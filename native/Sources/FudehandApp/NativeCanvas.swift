import AppKit
import SwiftUI
import FudehandCore

/// Embeds the AppKit canvas in SwiftUI. The store pushes the document directly to the canvas (updated every frame during a drag, bypassing SwiftUI);
/// only one-off viewport requests and the current tool are passed here.
struct NativeCanvas: NSViewRepresentable {
    let store: FudehandStore
    let viewportRequest: ViewportRequest
    let tool: CanvasTool
    /// The floating toolbar's frame in the canvas's coordinates.
    var toolbarFrame = CGRect.zero

    func makeNSView(context: Context) -> FudehandCanvasView {
        let view = FudehandCanvasView()
        view.host = store
        view.zoomIndicator = store.zoomIndicator
        store.attach(view)
        view.update(viewportRequest: viewportRequest, tool: tool)
        view.floatingFrame = toolbarFrame
        return view
    }

    func updateNSView(_ view: FudehandCanvasView, context: Context) {
        view.update(viewportRequest: viewportRequest, tool: tool)
        view.floatingFrame = toolbarFrame
    }

    static func dismantleNSView(_ view: FudehandCanvasView, coordinator: ()) {
        view.dispose()
    }
}
