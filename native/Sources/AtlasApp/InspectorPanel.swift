import AppKit
import AtlasCore
import SwiftUI

/// The inspector on the right: the "Design" tab edits the properties of the selected layers, and the "Chat" tab is the Agent chat panel.
struct InspectorPanel: View {
    @ObservedObject var store: AtlasStore

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Inspector"), selection: $store.inspectorTab) {
                Text(L("Design")).tag(InspectorTab.design)
                Text(L("Chat")).tag(InspectorTab.chat)
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
                    Section(title: L("%d layers selected", selected.count)) {
                        SliderRow(label: L("Opacity"), value: selected.map(\.opacity).reduce(0, +) / Double(selected.count)) { value in
                            store.edit("Change Opacity", coalescing: "\(selected.map(\.id).sorted().joined(separator: ",")).opacity") { document in
                                for node in selected { try document.update(node.id) { $0.opacity = value } }
                            }
                        }
                    }
                } else {
                    Section(title: L("Document")) {
                        LabeledContent(L("Name"), value: store.title)
                        LabeledContent(L("Layers"), value: "\(store.document.nodeCount)")
                        Text(L("Select a layer to edit its position, size, fill, stroke, text, and auto layout here."))
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

/// Number input: committed on Return or when focus is lost.
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
        let limit = DesignJSON.maximumMagnitude
        let clamped = min(limit, max(minimum ?? -limit, number))
        if clamped != value { commit(clamped) }
        text = Self.format(clamped)
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
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
            TextField(L("Hex"), text: $hex).textFieldStyle(.roundedBorder).monospaced()
                .onSubmit { if let next = try? DesignColor(hex: hex.hasPrefix("#") ? hex : "#" + hex) { commit(next) } else { hex = color.hex } }
                .accessibilityLabel(L("%@ hex", label))
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
            TextField(L("Name"), text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { let trimmed = name.trimmingCharacters(in: .whitespaces); if !trimmed.isEmpty { update("Rename Layer") { $0.name = trimmed } } }
                .onAppear { name = node.name }
                .onChange(of: node.name) { _, next in name = next }
                .accessibilityLabel(L("Layer name"))
        }
        Section(title: L("Position and Size")) {
            let inLayout = parentLayout != nil
            HStack {
                NumberField(label: "X", value: node.x, disabled: inLayout) { v in update("Change Position") { $0.x = v } }
                NumberField(label: "Y", value: node.y, disabled: inLayout) { v in update("Change Position") { $0.y = v } }
            }
            HStack {
                NumberField(label: "W", value: node.width, minimum: 0, disabled: node.type == .group) { v in
                    update("Change Size") { $0.width = v; $0.sizing.horizontal = .fixed; if $0.text?.autoResize == .widthAndHeight { $0.text?.autoResize = .height } }
                }
                NumberField(label: "H", value: node.height, minimum: 0, disabled: node.type == .group) { v in
                    update("Change Size") { $0.height = v; $0.sizing.vertical = .fixed; if $0.text != nil { $0.text?.autoResize = .none } }
                }
            }
            // A group's size always equals the union of its child layers, so sizing modes have no effect on it (#60).
            if node.type != .group && (inLayout || node.layout != nil || node.type == .text) {
                sizingPicker(L("Width"), node.sizing.horizontal) { mode in update("Change Sizing") { $0.sizing.horizontal = mode } }
                sizingPicker(L("Height"), node.sizing.vertical) { mode in update("Change Sizing") { $0.sizing.vertical = mode } }
            }
        }
        Section(title: L("Appearance")) {
            SliderRow(label: L("Opacity"), value: node.opacity) { v in update("Change Opacity", "opacity") { $0.opacity = v } }
            if node.type.hasCornerRadius {
                NumberField(label: L("Corner radius"), value: node.cornerRadius, minimum: 0) { v in update("Change Corner Radius") { $0.cornerRadius = v } }
            }
            if node.type == .frame {
                Toggle(L("Clip content"), isOn: Binding(get: { node.clipsContent }, set: { v in update("Change Clipping") { $0.clipsContent = v } }))
            }
        }
        Group {
            Section(title: node.type == .text ? L("Background") : L("Fill")) {
                if let fill = node.fill {
                    HStack {
                        ColorRow(label: L("Fill"), color: fill) { c in update("Change Fill", "fill") { $0.fill = c } }
                        Button { update("Remove Fill") { $0.fill = nil } } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless).help(L("Remove fill")).accessibilityLabel(L("Remove fill"))
                    }
                } else {
                    Button(L("Add Fill")) { update("Add Fill") { $0.fill = .white } }
                }
            }
            Section(title: L("Stroke")) {
                if let stroke = node.stroke {
                    HStack {
                        ColorRow(label: L("Stroke"), color: stroke.color) { c in update("Change Stroke", "stroke") { $0.stroke?.color = c } }
                        Button { update("Remove Stroke") { $0.stroke = nil } } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless).help(L("Remove stroke")).accessibilityLabel(L("Remove stroke"))
                    }
                    NumberField(label: L("Weight|stroke"), value: stroke.width, minimum: 0) { v in update("Change Stroke") { $0.stroke?.width = v } }
                } else {
                    Button(L("Add Stroke")) { update("Add Stroke") { $0.stroke = DesignStroke(color: .black, width: 1) } }
                }
            }
        }
        if let text = node.text { textSection(text) }
        if node.type == .frame { layoutSection(node.layout) }
        if let image = node.image {
            Section(title: L("Image")) {
                Picker(L("Scaling"), selection: Binding(get: { image.fit }, set: { v in update("Change Image Scaling") { $0.image?.fit = v } })) {
                    Text(L("Fill|image scaling")).tag(ImageFit.fill)
                    Text(L("Fit|image scaling")).tag(ImageFit.fit)
                    Text(L("Stretch")).tag(ImageFit.stretch)
                }
                Button(L("Replace Image…")) { replaceImage() }
            }
        }
    }

    private func sizingPicker(_ label: String, _ mode: SizingMode, _ commit: @escaping (SizingMode) -> Void) -> some View {
        Picker(label, selection: Binding(get: { mode }, set: commit)) {
            Text(L("Fixed")).tag(SizingMode.fixed)
            Text(L("Hug contents")).tag(SizingMode.hug)
            Text(L("Fill container")).tag(SizingMode.fill)
        }
    }

    private func textSection(_ text: DesignText) -> some View {
        Section(title: L("Text")) {
            TextEditor(text: $content)
                .font(.system(size: 12)).frame(minHeight: 54, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .onAppear { content = text.content }
                .onChange(of: text.content) { _, next in if next != content { content = next } }
                .onChange(of: content) { _, next in
                    if next != node.text?.content { update("Change Text", "text.content") { $0.text?.content = next } }
                }
                .accessibilityLabel(L("Text content"))
            HStack {
                NumberField(label: L("Font size"), value: text.fontSize, minimum: 1) { v in update("Change Font Size") { $0.text?.fontSize = v } }
                Picker(L("Weight|font"), selection: Binding(get: { text.fontWeight }, set: { v in update("Change Font Weight") { $0.text?.fontWeight = v } })) {
                    ForEach([100, 200, 300, 400, 500, 600, 700, 800, 900], id: \.self) { Text(Self.weightName($0)).tag($0) }
                }.labelsHidden()
            }
            ColorRow(label: L("Text color"), color: text.color) { c in update("Change Text Color", "text.color") { $0.text?.color = c } }
            Picker(L("Alignment"), selection: Binding(get: { text.align }, set: { v in update("Change Alignment") { $0.text?.align = v } })) {
                Image(systemName: "text.alignleft").tag(TextAlign.left)
                Image(systemName: "text.aligncenter").tag(TextAlign.center)
                Image(systemName: "text.alignright").tag(TextAlign.right)
            }.pickerStyle(.segmented)
            Picker(L("Sizing"), selection: Binding(get: { text.autoResize }, set: { v in update("Change Text Sizing") { $0.text?.autoResize = v } })) {
                Text(L("Auto width and height")).tag(TextAutoResize.widthAndHeight)
                Text(L("Auto height")).tag(TextAutoResize.height)
                Text(L("Fixed")).tag(TextAutoResize.none)
            }
        }
    }

    static func weightName(_ weight: Int) -> String {
        [100: L("Thin"), 200: L("Extra Light"), 300: L("Light|font weight"), 400: L("Regular"), 500: L("Medium"), 600: L("Semibold"), 700: L("Bold"), 800: L("Extra Bold"), 900: L("Black")][weight] ?? "\(weight)"
    }

    private func layoutSection(_ layout: AutoLayout?) -> some View {
        Section(title: L("Auto Layout")) {
            if let layout {
                Picker(L("Direction"), selection: Binding(get: { layout.direction }, set: { v in update("Change Layout Direction") { $0.layout?.direction = v } })) {
                    Image(systemName: "arrow.down").tag(LayoutDirection.vertical)
                    Image(systemName: "arrow.right").tag(LayoutDirection.horizontal)
                }.pickerStyle(.segmented)
                NumberField(label: L("Spacing"), value: layout.spacing) { v in update("Change Spacing") { $0.layout?.spacing = v } }
                Text(L("Padding")).foregroundStyle(.secondary)
                HStack {
                    NumberField(label: L("Top"), value: layout.padding.top, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.top = v } }
                    NumberField(label: L("Right"), value: layout.padding.right, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.right = v } }
                }
                HStack {
                    NumberField(label: L("Bottom"), value: layout.padding.bottom, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.bottom = v } }
                    NumberField(label: L("Left"), value: layout.padding.left, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.left = v } }
                }
                Picker(L("Main axis"), selection: Binding(get: { layout.align }, set: { v in update("Change Alignment") { $0.layout?.align = v } })) {
                    Text(L("Start")).tag(LayoutAlign.start)
                    Text(L("Center")).tag(LayoutAlign.center)
                    Text(L("End")).tag(LayoutAlign.end)
                    Text(L("Space between")).tag(LayoutAlign.spaceBetween)
                }
                Picker(L("Cross axis"), selection: Binding(get: { layout.crossAlign }, set: { v in update("Change Alignment") { $0.layout?.crossAlign = v } })) {
                    Text(L("Start")).tag(LayoutCrossAlign.start)
                    Text(L("Center")).tag(LayoutCrossAlign.center)
                    Text(L("End")).tag(LayoutCrossAlign.end)
                    Text(L("Stretch")).tag(LayoutCrossAlign.stretch)
                }
                Button(L("Remove Auto Layout")) { update("Remove Auto Layout") { $0.layout = nil } }
            } else {
                Button(L("Add Auto Layout")) { update("Add Auto Layout") { $0.layout = AutoLayout(direction: .vertical, spacing: 8) } }
            }
        }
    }

    private func replaceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), DesignRenderer.cgImage(data) != nil else { return }
        update("Replace Image") { $0.image?.data = data }
    }
}
