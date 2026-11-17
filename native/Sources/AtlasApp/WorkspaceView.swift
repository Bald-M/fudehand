import AppKit
import AtlasCore
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: AtlasStore

    var body: some View {
        NavigationSplitView {
            LayersPanel(store: store).navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            NativeCanvas(store: store, viewportRequest: store.viewportRequest, tool: store.tool)
                .clipped()
                .navigationTitle(store.title + (store.isDirty ? " — 已编辑" : ""))
        }
        .inspector(isPresented: $store.showingInspector) {
            InspectorPanel(store: store).inspectorColumnWidth(min: 260, ideal: 300, max: 520)
        }
        .toolbar { toolbar }
        .alert("操作失败", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("好", role: .cancel) { store.alert = nil }
        } message: { Text(store.alert ?? "") }
    }

    private static let tools: [(CanvasTool, String, String)] = [
        (.move, "移动 V", "cursorarrow"), (.hand, "抓手 H", "hand.raised"), (.frame, "画框 F", "number"),
        (.rectangle, "矩形 R", "rectangle"), (.ellipse, "椭圆 O", "circle"), (.text, "文字 T", "textformat"),
    ]

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("工具", selection: $store.tool) {
                ForEach(Self.tools, id: \.0) { tool, title, symbol in
                    Label(title, systemImage: symbol).tag(tool).help(title)
                }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel("画布工具")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.insertImage() } label: { Image(systemName: "photo.badge.plus") }
                .help("插入图片").accessibilityLabel("插入图片")
            Divider()
            Button { store.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("缩小（⌘−）").accessibilityLabel("缩小")
            ZoomLabel(indicator: store.zoomIndicator) { store.zoom(1) }
            Button { store.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("放大（⌘+）").accessibilityLabel("放大")
            Button { store.fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("适应全部（⌘0）").accessibilityLabel("适应全部")
            Menu {
                Picker("外观", selection: $store.theme) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
            } label: { Image(systemName: "circle.lefthalf.filled") }.help("外观").accessibilityLabel("外观")
            Toggle(isOn: $store.showingInspector) { Image(systemName: "sidebar.right") }
                .help("检查器（⌥⌘I）").accessibilityLabel("检查器").keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

private struct ZoomLabel: View {
    @ObservedObject var indicator: ZoomIndicator
    let action: () -> Void

    var body: some View {
        Button("\(Int((indicator.scale * 100).rounded()))%", action: action)
            .monospacedDigit().frame(minWidth: 44).help("实际大小（⌘1）")
    }
}
