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
                .navigationTitle(store.isDirty ? L("%@ — Edited", store.title) : store.title)
        }
        .inspector(isPresented: $store.showingInspector) {
            InspectorPanel(store: store).inspectorColumnWidth(min: 260, ideal: 300, max: 520)
        }
        .toolbar { toolbar }
        .storeAlert(store)
    }

    /// Tool, name key, shortcut key, symbol.
    private static let tools: [(CanvasTool, String, String, String)] = [
        (.move, "Move", "V", "cursorarrow"), (.hand, "Hand", "H", "hand.raised"), (.frame, "Frame", "F", "number"),
        (.rectangle, "Rectangle", "R", "rectangle"), (.ellipse, "Ellipse", "O", "circle"), (.text, "Text", "T", "t.square"),
    ]

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(L("Tools"), selection: $store.tool) {
                ForEach(Self.tools, id: \.0) { tool, name, key, symbol in
                    let title = "\(L(name)) \(key)"
                    Label(title, systemImage: symbol).tag(tool).help(title)
                }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityLabel(L("Canvas tools"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.insertImage() } label: { Image(systemName: "photo.badge.plus") }
                .help(L("Insert Image")).accessibilityLabel(L("Insert Image"))
            Divider()
            Button { store.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help(L("Zoom Out (⌘−)")).accessibilityLabel(L("Zoom Out"))
            ZoomLabel(indicator: store.zoomIndicator) { store.zoom(1) }
            Button { store.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help(L("Zoom In (⌘+)")).accessibilityLabel(L("Zoom In"))
            Button { store.fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(L("Fit All (⌘0)")).accessibilityLabel(L("Fit All"))
            Menu {
                Picker(L("Appearance"), selection: $store.theme) {
                    Text(L("System")).tag("system")
                    Text(L("Light")).tag("light")
                    Text(L("Dark")).tag("dark")
                }
            } label: { Image(systemName: "circle.lefthalf.filled") }.help(L("Appearance")).accessibilityLabel(L("Appearance"))
            Toggle(isOn: $store.showingInspector) { Image(systemName: "sidebar.right") }
                .help(L("Inspector (⌥⌘I)")).accessibilityLabel(L("Inspector")).keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

private struct ZoomLabel: View {
    @ObservedObject var indicator: ZoomIndicator
    let action: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        Button("\(Int((indicator.scale * 100).rounded()))%", action: action)
            .monospacedDigit().frame(minWidth: 44).help(L("Actual Size (⌘1)"))
    }
}
