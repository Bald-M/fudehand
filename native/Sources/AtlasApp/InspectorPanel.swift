import AppKit
import AtlasCore
import SwiftUI

/// 右侧检查器：“设计”页编辑选中图层的属性，“对话”页是 Agent 对话面板。
struct InspectorPanel: View {
    @ObservedObject var store: AtlasStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $store.inspectorTab) {
                Text("设计").tag(InspectorTab.design)
                Text("对话").tag(InspectorTab.chat)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch store.inspectorTab {
            case .design: DesignInspector(store: store)
            case .chat:
                ChatPanel(chat: store.chat, root: store.toolsRoot, runtime: store.runtime) {
                    store.chat.send($0, root: store.toolsRoot, runtime: store.runtime)
                }
            }
        }
    }
}

private struct DesignInspector: View {
    @ObservedObject var store: AtlasStore

    var body: some View {
        let selected = store.selection.compactMap { store.document.node($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if selected.count == 1, let node = selected.first {
                    NodeInspector(store: store, node: node, parentLayout: parentLayout(of: node.id)).id(node.id)
                } else if selected.count > 1 {
                    Section(title: "已选 \(selected.count) 个图层") {
                        SliderRow(label: "透明度", value: selected.map(\.opacity).reduce(0, +) / Double(selected.count)) { value in
                            store.edit("修改透明度", coalescing: "selection.opacity") { document in
                                for node in selected { try document.update(node.id) { $0.opacity = value } }
                            }
                        }
                    }
                } else {
                    Section(title: "文档") {
                        LabeledContent("名称", value: store.title)
                        LabeledContent("图层", value: "\(store.document.nodeCount)")
                        Text("选中图层后在这里修改位置、尺寸、填充、描边、文字与自动布局。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func parentLayout(of id: String) -> AutoLayout? {
        guard let parent = store.document.parentID(of: id) ?? nil else { return nil }
        return store.document.node(parent)?.layout
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }
}

/// 数字输入：回车或失去焦点时提交。
private struct NumberField: View {
    let label: String
    let value: Double
    var minimum: Double? = nil
    var disabled = false
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .leading)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder).monospacedDigit().focused($focused)
                .onSubmit(submit)
                .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
                .accessibilityLabel(label)
        }
        .disabled(disabled)
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, next in if !focused { text = Self.format(next) } }
    }

    private func submit() {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { text = Self.format(value); return }
        let clamped = minimum.map { max($0, number) } ?? number
        if clamped != value { commit(clamped) }
        text = Self.format(clamped)
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private struct SliderRow: View {
    let label: String
    let value: Double
    let commit: (Double) -> Void

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: commit), in: 0...1)
            Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 38, alignment: .trailing)
        }
    }
}

extension DesignColor {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

private struct ColorRow: View {
    let label: String
    let color: DesignColor
    let commit: (DesignColor) -> Void
    @State private var hex = ""

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker(label, selection: Binding(get: { color.swiftUI }, set: { commit(DesignColor($0)) }), supportsOpacity: true)
                .labelsHidden()
            TextField("十六进制", text: $hex).textFieldStyle(.roundedBorder).monospaced()
                .onSubmit { if let next = try? DesignColor(hex: hex.hasPrefix("#") ? hex : "#" + hex) { commit(next) } else { hex = color.hex } }
                .accessibilityLabel("\(label)十六进制")
        }
        .onAppear { hex = color.hex }
        .onChange(of: color) { _, next in hex = next.hex }
    }
}

private struct NodeInspector: View {
    @ObservedObject var store: AtlasStore
    let node: DesignNode
    let parentLayout: AutoLayout?
    @State private var name = ""
    @State private var content = ""

    private func update(_ action: String, _ key: String? = nil, _ change: @escaping (inout DesignNode) -> Void) {
        store.updateNode(node.id, action, coalescing: key) { change(&$0) }
    }

    var body: some View {
        Section(title: node.type.title) {
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { let trimmed = name.trimmingCharacters(in: .whitespaces); if !trimmed.isEmpty { update("重命名图层") { $0.name = trimmed } } }
                .onAppear { name = node.name }
                .onChange(of: node.name) { _, next in name = next }
                .accessibilityLabel("图层名称")
        }
        Section(title: "位置与尺寸") {
            let inLayout = parentLayout != nil
            HStack {
                NumberField(label: "X", value: node.x, disabled: inLayout) { v in update("修改位置") { $0.x = v } }
                NumberField(label: "Y", value: node.y, disabled: inLayout) { v in update("修改位置") { $0.y = v } }
            }
            HStack {
                NumberField(label: "W", value: node.width, minimum: 0, disabled: node.type == .group) { v in
                    update("修改尺寸") { $0.width = v; $0.sizing.horizontal = .fixed; if $0.text?.autoResize == .widthAndHeight { $0.text?.autoResize = .height } }
                }
                NumberField(label: "H", value: node.height, minimum: 0, disabled: node.type == .group) { v in
                    update("修改尺寸") { $0.height = v; $0.sizing.vertical = .fixed; if $0.text != nil { $0.text?.autoResize = .none } }
                }
            }
            if inLayout || node.layout != nil || node.type == .text {
                sizingPicker("宽度", node.sizing.horizontal) { mode in update("修改尺寸模式") { $0.sizing.horizontal = mode } }
                sizingPicker("高度", node.sizing.vertical) { mode in update("修改尺寸模式") { $0.sizing.vertical = mode } }
            }
        }
        Section(title: "外观") {
            SliderRow(label: "透明度", value: node.opacity) { v in update("修改透明度", "opacity") { $0.opacity = v } }
            if node.type.hasCornerRadius {
                NumberField(label: "圆角", value: node.cornerRadius, minimum: 0) { v in update("修改圆角") { $0.cornerRadius = v } }
            }
            if node.type == .frame {
                Toggle("裁剪内容", isOn: Binding(get: { node.clipsContent }, set: { v in update("修改裁剪") { $0.clipsContent = v } }))
            }
        }
        Group {
            Section(title: node.type == .text ? "背景" : "填充") {
                if let fill = node.fill {
                    HStack {
                        ColorRow(label: "填充", color: fill) { c in update("修改填充", "fill") { $0.fill = c } }
                        Button { update("移除填充") { $0.fill = nil } } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless).help("移除填充").accessibilityLabel("移除填充")
                    }
                } else {
                    Button("添加填充") { update("添加填充") { $0.fill = .white } }
                }
            }
            Section(title: "描边") {
                if let stroke = node.stroke {
                    HStack {
                        ColorRow(label: "描边", color: stroke.color) { c in update("修改描边", "stroke") { $0.stroke?.color = c } }
                        Button { update("移除描边") { $0.stroke = nil } } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless).help("移除描边").accessibilityLabel("移除描边")
                    }
                    NumberField(label: "粗细", value: stroke.width, minimum: 0) { v in update("修改描边") { $0.stroke?.width = v } }
                } else {
                    Button("添加描边") { update("添加描边") { $0.stroke = DesignStroke(color: .black, width: 1) } }
                }
            }
        }
        if let text = node.text { textSection(text) }
        if node.type == .frame { layoutSection(node.layout) }
        if let image = node.image {
            Section(title: "图片") {
                Picker("适应方式", selection: Binding(get: { image.fit }, set: { v in update("修改图片适应方式") { $0.image?.fit = v } })) {
                    Text("填满").tag(ImageFit.fill)
                    Text("适应").tag(ImageFit.fit)
                    Text("拉伸").tag(ImageFit.stretch)
                }
                Button("替换图片…") { replaceImage() }
            }
        }
    }

    private func sizingPicker(_ label: String, _ mode: SizingMode, _ commit: @escaping (SizingMode) -> Void) -> some View {
        Picker(label, selection: Binding(get: { mode }, set: commit)) {
            Text("固定").tag(SizingMode.fixed)
            Text("包裹内容").tag(SizingMode.hug)
            Text("填满容器").tag(SizingMode.fill)
        }
    }

    private func textSection(_ text: DesignText) -> some View {
        Section(title: "文字") {
            TextEditor(text: $content)
                .font(.system(size: 12)).frame(minHeight: 54, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .onAppear { content = text.content }
                .onChange(of: text.content) { _, next in if next != content { content = next } }
                .onChange(of: content) { _, next in
                    if next != node.text?.content { update("修改文字", "text.content") { $0.text?.content = next } }
                }
                .accessibilityLabel("文字内容")
            HStack {
                NumberField(label: "字号", value: text.fontSize, minimum: 1) { v in update("修改字号") { $0.text?.fontSize = v } }
                Picker("字重", selection: Binding(get: { text.fontWeight }, set: { v in update("修改字重") { $0.text?.fontWeight = v } })) {
                    ForEach([100, 200, 300, 400, 500, 600, 700, 800, 900], id: \.self) { Text(Self.weightName($0)).tag($0) }
                }.labelsHidden()
            }
            ColorRow(label: "文字颜色", color: text.color) { c in update("修改文字颜色", "text.color") { $0.text?.color = c } }
            Picker("对齐", selection: Binding(get: { text.align }, set: { v in update("修改对齐") { $0.text?.align = v } })) {
                Image(systemName: "text.alignleft").tag(TextAlign.left)
                Image(systemName: "text.aligncenter").tag(TextAlign.center)
                Image(systemName: "text.alignright").tag(TextAlign.right)
            }.pickerStyle(.segmented)
            Picker("尺寸", selection: Binding(get: { text.autoResize }, set: { v in update("修改文字尺寸") { $0.text?.autoResize = v } })) {
                Text("自动宽高").tag(TextAutoResize.widthAndHeight)
                Text("自动高度").tag(TextAutoResize.height)
                Text("固定").tag(TextAutoResize.none)
            }
        }
    }

    static func weightName(_ weight: Int) -> String {
        [100: "极细", 200: "纤细", 300: "细", 400: "常规", 500: "中等", 600: "半粗", 700: "粗", 800: "特粗", 900: "黑"][weight] ?? "\(weight)"
    }

    private func layoutSection(_ layout: AutoLayout?) -> some View {
        Section(title: "自动布局") {
            if let layout {
                Picker("方向", selection: Binding(get: { layout.direction }, set: { v in update("修改布局方向") { $0.layout?.direction = v } })) {
                    Image(systemName: "arrow.down").tag(LayoutDirection.vertical)
                    Image(systemName: "arrow.right").tag(LayoutDirection.horizontal)
                }.pickerStyle(.segmented)
                NumberField(label: "间距", value: layout.spacing) { v in update("修改间距") { $0.layout?.spacing = v } }
                Text("内边距").foregroundStyle(.secondary)
                HStack {
                    NumberField(label: "上", value: layout.padding.top, minimum: 0) { v in update("修改内边距") { $0.layout?.padding.top = v } }
                    NumberField(label: "右", value: layout.padding.right, minimum: 0) { v in update("修改内边距") { $0.layout?.padding.right = v } }
                }
                HStack {
                    NumberField(label: "下", value: layout.padding.bottom, minimum: 0) { v in update("修改内边距") { $0.layout?.padding.bottom = v } }
                    NumberField(label: "左", value: layout.padding.left, minimum: 0) { v in update("修改内边距") { $0.layout?.padding.left = v } }
                }
                Picker("主轴", selection: Binding(get: { layout.align }, set: { v in update("修改对齐") { $0.layout?.align = v } })) {
                    Text("起点").tag(LayoutAlign.start)
                    Text("居中").tag(LayoutAlign.center)
                    Text("终点").tag(LayoutAlign.end)
                    Text("两端分布").tag(LayoutAlign.spaceBetween)
                }
                Picker("交叉轴", selection: Binding(get: { layout.crossAlign }, set: { v in update("修改对齐") { $0.layout?.crossAlign = v } })) {
                    Text("起点").tag(LayoutCrossAlign.start)
                    Text("居中").tag(LayoutCrossAlign.center)
                    Text("终点").tag(LayoutCrossAlign.end)
                    Text("拉伸").tag(LayoutCrossAlign.stretch)
                }
                Button("移除自动布局") { update("移除自动布局") { $0.layout = nil } }
            } else {
                Button("添加自动布局") { update("添加自动布局") { $0.layout = AutoLayout(direction: .vertical, spacing: 8) } }
            }
        }
    }

    private func replaceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), DesignRenderer.cgImage(data) != nil else { return }
        update("替换图片") { $0.image?.data = data }
    }
}
