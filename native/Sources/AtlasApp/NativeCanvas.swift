import AppKit
import SwiftUI
import AtlasCore

/// Embeds the AppKit canvas in SwiftUI. The store pushes the document directly to the canvas (updated every frame during a drag, bypassing SwiftUI);
/// only one-off viewport requests and the current tool are passed here.
struct NativeCanvas: NSViewRepresentable {
    let store: AtlasStore
    let viewportRequest: ViewportRequest
    let tool: CanvasTool

    func makeNSView(context: Context) -> AtlasCanvasView {
        let view = AtlasCanvasView()
        view.host = store
        view.zoomIndicator = store.zoomIndicator
        store.attach(view)
        view.update(viewportRequest: viewportRequest, tool: tool)
        return view
    }

    func updateNSView(_ view: AtlasCanvasView, context: Context) {
        view.update(viewportRequest: viewportRequest, tool: tool)
    }

    static func dismantleNSView(_ view: AtlasCanvasView, coordinator: ()) {
        view.dispose()
    }
}
