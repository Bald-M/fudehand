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
        case .group: return "rectangle.3.group"
        }
    }
}

/// The layers panel: the hierarchy tree (upper layers first, matching the canvas stacking order), show/hide, lock, rename, kept in sync with the canvas selection.
struct LayersPanel: View {
    @ObservedObject var store: FudehandStore
    @State private var collapsed: Set<String> = []
    @State private var renaming: String?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    /// A row carries only its own properties (not the subtree), so the cost of comparing the list is linear in the number of layers.
    private struct Row: Identifiable {
        let node: DesignNode
        let hasChildren: Bool
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [Row] {
        var result: [Row] = []
        func visit(_ nodes: [DesignNode], depth: Int) {
            // Upper layers come first in the list.
            for node in nodes.reversed() {
                var shallow = node
                shallow.children = []
                result.append(Row(node: shallow, hasChildren: !node.children.isEmpty, depth: depth))
                if !collapsed.contains(node.id) { visit(node.children, depth: depth + 1) }
            }
        }
        visit(store.document.nodes, depth: 0)
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Layers")).font(.headline)
                Spacer()
                Text("\(store.document.nodeCount)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if store.document.nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d").font(.title2).foregroundStyle(.secondary)
                    Text(L("No layers yet")).font(.callout)
                    Text(L("Create layers on the canvas with the Frame, Rectangle, or Text tool in the toolbar, or ask an Agent to build the interface."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in rowView(row) }
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        SelectionReader(selection: store.layerSelection, id: row.id) { selected in rowView(row, selected: selected) }
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        let node = row.node
        return HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            Button { toggleCollapsed(node.id) } label: {
                Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 12)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(row.hasChildren ? 1 : 0).disabled(!row.hasChildren)
            .accessibilityLabel(collapsed.contains(node.id) ? L("Expand") : L("Collapse"))
            Image(systemName: node.layout != nil ? "square.split.1x2" : node.type.symbol)
                .font(.system(size: 11)).frame(width: 16).foregroundStyle(selected ? Color.accentColor : .secondary)
            if renaming == node.id {
                TextField(L("Name"), text: $draftName)
                    .textFieldStyle(.plain).focused($renameFocused)
                    .onSubmit { commitRename(node.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(node.id) } }
            } else {
                Text(node.name).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(node.visible ? .primary : .secondary)
                Spacer(minLength: 4)
            }
            Button { store.updateNode(node.id, node.locked ? "Unlock Layer" : "Lock Layer") { $0.locked.toggle() } } label: {
                Image(systemName: node.locked ? "lock.fill" : "lock.open").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(node.locked ? 1 : 0.35)
            .help(node.locked ? L("Unlock") : L("Lock")).accessibilityLabel(node.locked ? L("Unlock %@", node.name) : L("Lock %@", node.name))
            Button { store.updateNode(node.id, node.visible ? "Hide Layer" : "Show Layer") { $0.visible.toggle() } } label: {
                Image(systemName: node.visible ? "eye" : "eye.slash").font(.system(size: 10))
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
            Button(L("Bring Forward")) { step(node.id, by: 1) }
            Button(L("Send Backward")) { step(node.id, by: -1) }
            Button(L("Bring to Front")) { reorder(node.id, toTop: true) }
            Button(L("Send to Back")) { reorder(node.id, toTop: false) }
            Divider()
            Button(L("Zoom to Layer")) { store.focus(node.id) }
            Divider()
            Button(L("Delete"), role: .destructive) { store.canvasDelete([node.id]) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.type.title) \(node.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { store.setSelection([node.id]) }
    }

    private func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// Acts when the button goes down; the drag updates that follow the press are ignored.
    private func press(_ node: DesignNode) {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return }
        let flags = event.modifierFlags
        switch LayerRowPress.resolve(id: node.id, selection: store.selection, clickCount: event.clickCount,
                                     command: flags.contains(.command), shift: flags.contains(.shift)) {
        case .select(let ids): store.setSelection(ids)
        case .rename: beginRename(node)
        }
    }

    private func beginRename(_ node: DesignNode) {
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
