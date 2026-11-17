import AppKit
import AtlasCore
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

/// 图层面板：层级树（上层在前，与画布层叠顺序一致），显示/隐藏、锁定、重命名，与画布选择同步。
struct LayersPanel: View {
    @ObservedObject var store: AtlasStore
    @State private var collapsed: Set<String> = []
    @State private var renaming: String?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    private struct Row: Identifiable {
        let node: DesignNode
        let depth: Int
        let parentLayout: Bool
        var id: String { node.id }
    }

    private var rows: [Row] {
        var result: [Row] = []
        func visit(_ nodes: [DesignNode], depth: Int, parentLayout: Bool) {
            // 列表里上层在前。
            for node in nodes.reversed() {
                result.append(Row(node: node, depth: depth, parentLayout: parentLayout))
                if !collapsed.contains(node.id) { visit(node.children, depth: depth + 1, parentLayout: node.layout != nil) }
            }
        }
        visit(store.document.nodes, depth: 0, parentLayout: false)
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("图层").font(.headline)
                Spacer()
                Text("\(store.document.nodeCount)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if store.document.nodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d").font(.title2).foregroundStyle(.secondary)
                    Text("还没有图层").font(.callout)
                    Text("用工具栏的画框、矩形、文字工具在画布上创建，或让 Agent 搭建界面。")
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
        let node = row.node
        let selected = store.selection.contains(node.id)
        return HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            Button { toggleCollapsed(node.id) } label: {
                Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 12)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(node.children.isEmpty ? 0 : 1).disabled(node.children.isEmpty)
            .accessibilityLabel(collapsed.contains(node.id) ? "展开" : "折叠")
            Image(systemName: node.layout != nil ? "square.split.1x2" : node.type.symbol)
                .font(.system(size: 11)).frame(width: 16).foregroundStyle(selected ? Color.accentColor : .secondary)
            if renaming == node.id {
                TextField("名称", text: $draftName)
                    .textFieldStyle(.plain).focused($renameFocused)
                    .onSubmit { commitRename(node.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(node.id) } }
            } else {
                Text(node.name).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(node.visible ? .primary : .secondary)
                Spacer(minLength: 4)
            }
            Button { store.updateNode(node.id, node.locked ? "解锁图层" : "锁定图层") { $0.locked.toggle() } } label: {
                Image(systemName: node.locked ? "lock.fill" : "lock.open").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(node.locked ? 1 : 0.35)
            .help(node.locked ? "解锁" : "锁定").accessibilityLabel(node.locked ? "解锁\(node.name)" : "锁定\(node.name)")
            Button { store.updateNode(node.id, node.visible ? "隐藏图层" : "显示图层") { $0.visible.toggle() } } label: {
                Image(systemName: node.visible ? "eye" : "eye.slash").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(node.visible ? 0.35 : 1)
            .help(node.visible ? "隐藏" : "显示").accessibilityLabel(node.visible ? "隐藏\(node.name)" : "显示\(node.name)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(height: 26)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(node) }
        .onTapGesture { select(node.id) }
        .contextMenu {
            Button("重命名") { beginRename(node) }
            Button("上移一层") { step(node.id, by: 1) }
            Button("下移一层") { step(node.id, by: -1) }
            Button("移到最上层") { reorder(node.id, toTop: true) }
            Button("移到最下层") { reorder(node.id, toTop: false) }
            Divider()
            Button("缩放至图层") { store.focus(node.id) }
            Divider()
            Button("删除", role: .destructive) { store.canvasDelete([node.id]) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.type.title) \(node.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// ⌘ 点击加入或移出选择，Shift 点击加入选择，普通点击单选。
    private func select(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { store.setSelection(store.selection.symmetricDifference([id])) }
        else if flags.contains(.shift) { store.setSelection(store.selection.union([id])) }
        else { store.setSelection([id]) }
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
        store.updateNode(id, "重命名图层") { $0.name = name }
    }

    /// 在同一父图层内上移（+1）或下移（-1）一层；已在最上或最下时不变。
    private func step(_ id: String, by offset: Int) {
        let document = store.editor.document
        guard let parent = document.parentID(of: id), let index = document.indexPath(of: id)?.last else { return }
        let count = (parent.flatMap { document.node($0)?.children } ?? document.nodes).count
        let target = index + offset
        guard (0..<count).contains(target) else { return }
        store.edit(offset > 0 ? "上移一层" : "下移一层") { try $0.move(id, parent: parent, index: target) }
    }

    private func reorder(_ id: String, toTop: Bool) {
        let document = store.editor.document
        guard let parent = document.parentID(of: id) else { return }
        let count = (parent.flatMap { document.node($0)?.children } ?? document.nodes).count
        store.edit(toTop ? "移到最上层" : "移到最下层") { try $0.move(id, parent: parent, index: toTop ? count - 1 : 0) }
    }
}
