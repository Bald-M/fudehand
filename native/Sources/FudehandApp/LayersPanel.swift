import AppKit
import FudehandCore
import SwiftUI

extension NodeType {
    var symbol: String {
        switch self {
        case .frame: return "number"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "t.square"
        case .image: return "photo"
        case .icon: return "star.square"
        case .group: return "rectangle.3.group"
        }
    }
}

extension DesignNode {
    /// What the inspector header calls this layer: its component role when it has one, otherwise its type.
    var kindTitle: String {
        if componentSet != nil { return L("Component Set") }
        if variant != nil { return L("Variant") }
        if component { return L("Main Component") }
        if instance != nil { return L("Instance") }
        return type.title
    }

    /// The symbol for this layer, matching its row in the layers panel.
    var kindSymbol: String {
        if componentSet != nil { return "square.grid.2x2" }
        if component { return "square.on.square.dashed" }
        if instance != nil { return "diamond" }
        return layout != nil ? "square.split.1x2" : type.symbol
    }
}

/// The rows of the layers panel, published apart from the store. The store updates them after every edit, and they change
/// only with what the rows show: moving or restyling layers on the canvas leaves the panel alone (#228).
final class LayerOutline: ObservableObject {
    /// A row carries only what it shows, so an edit that changes nothing shown leaves the rows equal.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let type: NodeType
        let hasLayout: Bool
        let visible: Bool
        let locked: Bool
        let hasChildren: Bool
        let collapsed: Bool
        let depth: Int
        let component: Bool
        let componentSet: Bool
        let instance: Bool
        let overridden: Bool

        var symbol: String {
            if componentSet { return "square.grid.2x2" }
            if component { return "square.on.square.dashed" }
            if instance { return "diamond" }
            return hasLayout ? "square.split.1x2" : type.symbol
        }

        var kind: String { componentSet ? L("Component Set") : component ? L("Main Component") : instance ? L("Instance") : type.title }
    }

    @Published private(set) var rows: [Row] = []
    /// The number of layers, collapsed ones included.
    @Published private(set) var count = 0

    func update(_ index: DesignIndex, collapsed: Set<String>) {
        var next: [Row] = []
        next.reserveCapacity(rows.count)
        func visit(_ nodes: [DesignNode], depth: Int) {
            // Upper layers come first in the list.
            for node in nodes.reversed() {
                let isCollapsed = collapsed.contains(node.id)
                next.append(Row(id: node.id, name: node.name, type: node.type, hasLayout: node.layout != nil, visible: node.visible,
                                locked: node.locked, hasChildren: !node.children.isEmpty, collapsed: isCollapsed, depth: depth,
                                component: node.component, componentSet: node.componentSet != nil, instance: node.instance != nil,
                                overridden: !node.overrides.isEmpty))
                if !isCollapsed { visit(node.children, depth: depth + 1) }
            }
        }
        visit(index.document.nodes, depth: 0)
        if next != rows { rows = next }
        if index.count != count { count = index.count }
    }
}

/// The layers panel: the hierarchy tree (upper layers first, matching the canvas stacking order), show/hide, lock, rename, kept in sync with the canvas selection.
struct LayersPanel: View {
    let store: FudehandStore
    @ObservedObject private var outline: LayerOutline
    @Environment(\.locale) private var locale
    @State private var renaming: String?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool
    @State private var showsRows = false

    init(store: FudehandStore) {
        self.store = store
        outline = store.layerOutline
    }

    private typealias Row = LayerOutline.Row

    var body: some View {
        let _ = locale // Re-render when the UI language changes: the panel does not observe the store.
        VStack(spacing: 0) {
            HStack {
                Text(L("Layers")).font(.headline)
                Spacer()
                Text("\(outline.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if outline.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d").font(.title2).foregroundStyle(.secondary)
                    Text(L("No layers yet")).font(.callout)
                    Text(L("Create layers on the canvas with the Frame, Rectangle, or Text tool in the toolbar, or ask an Agent to build the interface."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if showsRows {
                        LazyVStack(spacing: 0) {
                            ForEach(outline.rows) { row in rowView(row) }
                        }.padding(.vertical, 4)
                    }
                }
                // The first rows are built in a later main-thread turn than the window, so opening the editor window does
                // not block for both at once (#252).
                .task { showsRows = true }
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        SelectionReader(selection: store.layerSelection, id: row.id) { selected in rowView(row, selected: selected) }
    }

    private func rowView(_ node: Row, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(node.depth) * 14, height: 1)
            Button { store.setCollapsed(node.id, !node.collapsed) } label: {
                Image(systemName: node.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(node.hasChildren ? 1 : 0).disabled(!node.hasChildren)
            .accessibilityLabel(node.collapsed ? L("Expand") : L("Collapse"))
            Image(systemName: node.symbol)
                .font(.system(size: 11)).frame(width: 16).foregroundStyle(selected ? Color.accentColor : .secondary)
                .accessibilityLabel(node.kind)
            if renaming == node.id {
                TextField(L("Name"), text: $draftName)
                    .textFieldStyle(.plain).focused($renameFocused)
                    .onSubmit { commitRename(node.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(node.id) } }
            } else {
                Text(node.name).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(node.visible ? .primary : .secondary)
                if node.overridden {
                    Circle().fill(Color.accentColor.opacity(0.7)).frame(width: 5, height: 5)
                        .help(L("Overridden")).accessibilityLabel(L("Overridden"))
                }
                Spacer(minLength: 4)
            }
            Button { store.updateNode(node.id, node.locked ? "Unlock Layer" : "Lock Layer") { $0.locked.toggle() } } label: {
                Image(systemName: node.locked ? "lock.fill" : "lock.open").font(.system(size: 11)).iconHitTarget()
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(node.locked ? 1 : 0.35)
            .help(node.locked ? L("Unlock") : L("Lock")).accessibilityLabel(node.locked ? L("Unlock %@", node.name) : L("Lock %@", node.name))
            Button { store.updateNode(node.id, node.visible ? "Hide Layer" : "Show Layer") { $0.visible.toggle() } } label: {
                Image(systemName: node.visible ? "eye" : "eye.slash").font(.system(size: 11)).iconHitTarget()
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(node.visible ? 0.35 : 1)
            .help(node.visible ? L("Hide") : L("Show")).accessibilityLabel(node.visible ? L("Hide %@", node.name) : L("Show %@", node.name))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(height: 26)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        .background(HoverBackground(hover: store.hover, id: node.id))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { store.setHover(node.id) } else if store.hover.id == node.id { store.setHover(nil) }
        }
        .gesture(renaming == node.id ? nil : DragGesture(minimumDistance: 0).onChanged { _ in press(node) })
        .contextMenu {
            Button(L("Rename")) { beginRename(node) }
            Group {
                Button(L("Bring Forward")) { step(node.id, by: 1) }
                Button(L("Send Backward")) { step(node.id, by: -1) }
                Button(L("Bring to Front")) { reorder(node.id, toTop: true) }
                Button(L("Send to Back")) { reorder(node.id, toTop: false) }
            }
            .disabled(store.hasLayersInsideInstance([node.id]))
            Divider()
            Button(L("Copy")) { store.canvasCopy(targets(node), cut: false) }
            Button(L("Cut")) { store.canvasCopy(targets(node), cut: true) }.disabled(store.hasLayersInsideInstance(targets(node)))
            Button(L("Paste")) { guard store.canPasteLayers else { return }; store.setSelection([node.id]); store.paste() }
            Button(L("Duplicate")) { store.setSelection(targets(node)); store.duplicateSelection() }.disabled(store.hasLayersInsideInstance(targets(node)))
            Divider()
            Button(L("Create Component")) { store.createComponent(from: [node.id]) }
                .disabled(!store.canCreateComponent([node.id]))
            Button(L("Combine as Variants")) { store.combineAsVariants(from: targets(node)) }
                .disabled(!store.canCombineAsVariants(targets(node)))
            Button(L("Detach Instance")) { store.detachInstances(from: targets(node)) }
                .disabled(!store.canDetachInstances(targets(node)))
            Divider()
            Button(L("Zoom to Layer")) { store.focus(node.id) }
            Button(L("Export as HTML…")) { store.setSelection([node.id]); store.exportHTMLWithPanel() }
            Divider()
            Button(L("Delete"), role: .destructive) { store.canvasDelete([node.id]) }.disabled(store.hasLayersInsideInstance([node.id]))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.kind) \(node.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { store.setSelection([node.id]) }
    }

    /// What Copy, Cut, and Duplicate in a row's context menu act on: the selection when the row is part of it, otherwise the row.
    private func targets(_ node: Row) -> Set<String> {
        store.selection.contains(node.id) ? store.selection : [node.id]
    }

    /// Acts when the button goes down; the drag updates that follow the press are ignored.
    private func press(_ node: Row) {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return }
        let flags = event.modifierFlags
        switch LayerRowPress.resolve(id: node.id, selection: store.selection, clickCount: event.clickCount,
                                     command: flags.contains(.command), shift: flags.contains(.shift)) {
        case .select(let ids): store.setSelection(ids)
        case .rename: beginRename(node)
        }
    }

    private func beginRename(_ node: Row) {
        draftName = node.name
        renaming = node.id
        renameFocused = true
    }

    private func commitRename(_ id: String) {
        guard renaming == id else { return }
        renaming = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.updateNode(id, "Rename Layer") { $0.name = name }
    }

    /// Moves up (+1) or down (-1) one level within the same parent layer; unchanged when already at the top or bottom.
    private func step(_ id: String, by offset: Int) {
        let document = store.editor.document
        guard let parent = document.parentID(of: id), let index = document.indexPath(of: id)?.last else { return }
        let count = (parent.flatMap { document.node($0)?.children } ?? document.nodes).count
        let target = index + offset
        guard (0..<count).contains(target) else { return }
        store.edit(offset > 0 ? "Bring Forward" : "Send Backward") { try $0.move(id, parent: parent, index: target) }
    }

    private func reorder(_ id: String, toTop: Bool) {
        let document = store.editor.document
        guard let parent = document.parentID(of: id) else { return }
        let count = (parent.flatMap { document.node($0)?.children } ?? document.nodes).count
        store.edit(toTop ? "Bring to Front" : "Send to Back") { try $0.move(id, parent: parent, index: toTop ? count - 1 : 0) }
    }
}

/// Observes the selection on its own, so selecting redraws only the rows on screen, not the whole panel (#142).
private struct SelectionReader<Content: View>: View {
    @ObservedObject var selection: LayerSelection
    let id: String
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(selection.ids.contains(id)) }
}

/// Observes the hover on its own, so moving the pointer redraws only row backgrounds, not the whole panel.
private struct HoverBackground: View {
    @ObservedObject var hover: LayerHover
    let id: String

    var body: some View {
        hover.id == id ? Color.primary.opacity(0.06) : Color.clear
    }
}
