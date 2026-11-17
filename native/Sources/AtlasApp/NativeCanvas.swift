import AppKit
import SwiftUI
import AtlasCore

/// 把 AppKit 画布嵌入 SwiftUI。文档由 store 直接推送给画布（拖动时每帧更新，不经 SwiftUI）；
/// 这里只传递一次性的视口请求与当前工具。
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
