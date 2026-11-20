import AppKit
import FudehandCore
import SwiftUI

/// The inspector on the right: the "Design" tab edits the properties of the selected layers, and the "Chat" tab is the Agent chat panel.
struct InspectorPanel: View {
    @ObservedObject var store: FudehandStore
    @ObservedObject var selection: LayerSelection

    init(store: FudehandStore) {
        self.store = store
        selection = store.layerSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Inspector"), selection: $store.inspectorTab) {
                Text(L("Design")).tag(InspectorTab.design)
                Text(L("Chat")).tag(InspectorTab.chat)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch store.inspectorTab {
            case .design: DesignInspector(store: store, selection: selection)
            case .chat:
                let selected = selection.ids.compactMap { store.document.node($0) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                ChatPanel(chat: store.chat, root: store.toolsRoot, runtime: store.runtime,
                          selection: selected.map { ChatContext(id: $0.id, name: $0.name, type: $0.type.rawValue) },
                          layerName: { store.document.node($0)?.name })
            }
        }
    }
}

private struct DesignInspector: View {
    @ObservedObject var store: FudehandStore
    @ObservedObject var selection: LayerSelection

    var body: some View {
        let selected = selection.ids.compactMap { store.document.node($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if selected.count == 1, let node = selected.first {
                    // Kept when the selection moves to another layer, instead of rebuilt: rebuilding every control took most of the
                    // time of a selection change (#142). Fields reset their drafts on `inspectedLayer` instead.
                    NodeInspector(store: store, node: node, parentLayout: parentLayout(of: node.id)).environment(\.inspectedLayer, node.id)
                } else if selected.count > 1 {
                    Section(title: L("%d layers selected", selected.count)) {
                        SliderRow(label: L("Opacity"), value: selected.map(\.opacity).reduce(0, +) / Double(selected.count)) { value in
                            store.edit("Change Opacity", coalescing: "\(selected.map(\.id).sorted().joined(separator: ",")).opacity") { document in
                                for node in selected { try document.update(node.id) { $0.opacity = value } }
                            }
                        }
                    }
                    SelectionColorsSection(store: store, ids: selection.ids)
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
    @Environment(\.inspectedLayer) private var layer
    /// The layer the text was typed for. A draft typed for the previous layer is dropped, never committed to the newly
    /// selected one, whichever order SwiftUI reports the focus loss and the layer change in.
    @State private var draftLayer: String?

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
        .onAppear { text = NumberInput.format(value); draftLayer = layer }
        .onChange(of: value) { _, next in if !focused { text = NumberInput.format(next) } }
        .onChange(of: layer) { text = NumberInput.format(value); draftLayer = layer }
    }

    private func submit() {
        guard draftLayer == layer else { text = NumberInput.format(value); draftLayer = layer; return }
        let next = NumberInput.committedValue(text: text, current: value, minimum: minimum)
        if let next { commit(next) }
        text = NumberInput.format(next ?? value)
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

/// The layer the inspector shows; fields that hold a draft reset it when this changes.
private struct InspectedLayerKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    fileprivate var inspectedLayer: String? {
        get { self[InspectedLayerKey.self] }
        set { self[InspectedLayerKey.self] = newValue }
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
    @Environment(\.inspectedLayer) private var layer

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
        .onChange(of: layer) { hex = color.hex }
    }
}

/// Selection colors: every color the selected layers and their child layers use, most used first, as swatches; past the
/// first row a "+N" tile shows the rest. Clicking a swatch opens one editor below them, so only one color well exists
/// (a color well per swatch made selecting a frame several times slower in large documents).
private struct SelectionColorsSection: View {
    @ObservedObject var store: FudehandStore
    let ids: Set<String>
    @State private var expanded = false
    /// The swatch being edited: the uses that held its color when it was opened. Only they are written, so dragging the
    /// color through another selection color's value does not pick up that color's layers.
    @State private var editing: (hex: String, uses: [ColorUse])?
    private static let collapsedLimit = 7

    var body: some View {
        let colors = SelectionColors.collect(ids, in: store.document)
        let editedColor = editing.flatMap { edit in edit.uses.lazy.compactMap { SelectionColors.color(of: $0, in: store.document) }.first }
        Group {
            if !colors.isEmpty {
                let overflow = !expanded && colors.count > Self.collapsedLimit
                let shown = overflow ? Array(colors.prefix(Self.collapsedLimit - 1)) : colors
                Section(title: L("Selection Colors")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 24, maximum: 24), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(shown, id: \.color.hex) { usage in swatch(usage, selected: usage.color.hex == editedColor?.hex) }
                        if overflow {
                            Button { expanded = true } label: {
                                Text(verbatim: "+\(colors.count - shown.count)").monospacedDigit().frame(width: 24, height: 24).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .help(L("Show all %d colors", colors.count)).accessibilityLabel(L("Show all %d colors", colors.count))
                        }
                    }
                    if expanded && colors.count > Self.collapsedLimit {
                        Button(L("Show Fewer Colors")) { expanded = false }.buttonStyle(.link)
                    }
                    if let editing, let editedColor {
                        ColorRow(label: L("Selection color %@", editedColor.hex), color: editedColor) { color in
                            try? store.setColor(color, at: editing.uses, coalescing: "\(ids.sorted().joined(separator: ",")).selectionColor.\(editing.hex)")
                        }
                    }
                }
            }
        }
        .onChange(of: ids) { expanded = false; editing = nil }
    }

    private func swatch(_ usage: SelectionColor, selected: Bool) -> some View {
        Button {
            let hex = usage.color.hex
            editing = editing?.hex == hex ? nil : (hex, SelectionColors.uses(of: usage.color, under: ids, in: store.editor.document))
        } label: {
            RoundedRectangle(cornerRadius: 4).fill(usage.color.swiftUI).frame(width: 24, height: 24)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(-3).opacity(selected ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(usage.color.hex)
        .accessibilityLabel(L("Selection color %@", usage.color.hex))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NodeInspector: View {
    @ObservedObject var store: FudehandStore
    let node: DesignNode
    let parentLayout: AutoLayout?
    @State private var name = ""
    @State private var content = ""
    /// The text sequence's items, one per line.
    @State private var sequenceItems = ""
    @State private var previewing = false
    @State private var replacingIcon = false

    private func update(_ action: String, _ key: String? = nil, _ change: @escaping (inout DesignNode) -> Void) {
        store.updateNode(node.id, action, coalescing: key) { change(&$0) }
    }

    var body: some View {
        Section(title: node.type.title) {
            TextField(L("Name"), text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { let trimmed = name.trimmingCharacters(in: .whitespaces); if !trimmed.isEmpty { update("Rename Layer") { $0.name = trimmed } } }
                .onAppear { name = node.name }
                .onChange(of: node.name) { _, next in name = next }
                .onChange(of: node.id) { name = node.name; content = node.text?.content ?? ""; previewing = false }
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
                        Button { update("Remove Fill") { $0.fill = nil } } label: { Image(systemName: "minus").iconHitTarget() }
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
                        Button { update("Remove Stroke") { $0.stroke = nil } } label: { Image(systemName: "minus").iconHitTarget() }
                            .buttonStyle(.borderless).help(L("Remove stroke")).accessibilityLabel(L("Remove stroke"))
                    }
                    NumberField(label: L("Weight|stroke"), value: stroke.width, minimum: 0) { v in update("Change Stroke") { $0.stroke?.width = v } }
                } else {
                    Button(L("Add Stroke")) { update("Add Stroke") { $0.stroke = DesignStroke(color: .black, width: 1) } }
                }
            }
        }
        SelectionColorsSection(store: store, ids: [node.id])
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
        if let icon = node.icon {
            Section(title: L("Icon")) {
                LabeledContent(L("Icon name")) { Text(icon.name).textSelection(.enabled).monospaced() }
                ColorRow(label: L("Icon color"), color: icon.color) { c in update("Change Icon Color", "icon.color") { $0.icon?.color = c } }
                Button(L("Replace Icon…")) { replacingIcon = true }
                    .popover(isPresented: $replacingIcon, arrowEdge: .leading) {
                        IconPicker(current: icon.name) { store.replaceIcon(node.id, with: $0) }
                    }
            }
        }
        interactionSection(node.interaction)
        animationSection(node.animation)
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
            Picker(L("Font"), selection: Binding(get: { text.fontFamily ?? "" }, set: { v in update("Change Font") { $0.text?.fontFamily = v.isEmpty ? nil : v } })) {
                Text(L("System Default")).tag("")
                // A family this Mac does not have stays selectable, so the layer's setting is shown as it is.
                if let family = text.fontFamily, !store.fontFamilies.contains(where: { $0.name == family }) {
                    Text(L("%@ (missing)", family)).tag(family)
                }
                Divider()
                ForEach(store.fontFamilies, id: \.name) { Text($0.name).tag($0.name) }
            }
            HStack {
                NumberField(label: L("Font size"), value: text.fontSize, minimum: 1) { v in update("Change Font Size") { $0.text?.fontSize = v } }
                Picker(L("Weight|font"), selection: Binding(get: { text.fontWeight }, set: { v in update("Change Font Weight") { $0.text?.fontWeight = v } })) {
                    ForEach([100, 200, 300, 400, 500, 600, 700, 800, 900], id: \.self) { Text(Self.weightName($0)).tag($0) }
                }.labelsHidden()
            }
            ColorRow(label: L("Text color"), color: text.color) { c in update("Change Text Color", "text.color") { $0.text?.color = c } }
            Picker(L("Alignment"), selection: Binding(get: { text.align }, set: { v in update("Change Alignment") { $0.text?.align = v } })) {
                Image(systemName: "text.alignleft").accessibilityLabel(L("Left")).tag(TextAlign.left)
                Image(systemName: "text.aligncenter").accessibilityLabel(L("Center")).tag(TextAlign.center)
                Image(systemName: "text.alignright").accessibilityLabel(L("Right")).tag(TextAlign.right)
            }.pickerStyle(.segmented)
            Picker(L("Sizing"), selection: Binding(get: { text.autoResize }, set: { v in update("Change Text Sizing") { $0.text?.autoResize = v } })) {
                Text(L("Auto width and height")).tag(TextAutoResize.widthAndHeight)
                Text(L("Auto height")).tag(TextAutoResize.height)
                Text(L("Fixed")).tag(TextAutoResize.none)
            }
            Button(L("Import Font…")) { store.importFontFiles() }
            sequenceEditor(text)
        }
    }

    @ViewBuilder private func sequenceEditor(_ text: DesignText) -> some View {
        Divider()
        if let sequence = text.sequence {
            Text(L("Text Sequence")).foregroundStyle(.secondary)
            TextEditor(text: $sequenceItems)
                .font(.system(size: 12)).monospacedDigit().frame(minHeight: 54, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .onAppear { sequenceItems = sequence.items.joined(separator: "\n") }
                .onChange(of: node.id) { sequenceItems = node.text?.sequence?.items.joined(separator: "\n") ?? "" }
                .onChange(of: sequence.items) { _, next in if next != Self.items(sequenceItems) { sequenceItems = next.joined(separator: "\n") } }
                .onChange(of: sequenceItems) { _, next in
                    let items = Self.items(next)
                    if !items.isEmpty, items != node.text?.sequence?.items {
                        update("Change Text Sequence", "text.sequence.items") { $0.text?.sequence?.items = items }
                    }
                }
                .accessibilityLabel(L("Text sequence items"))
            Text(L("One item per line, shown in turn during playback.")).font(.caption).foregroundStyle(.secondary)
            NumberField(label: L("Interval (s)"), value: sequence.interval, minimum: TextSequence.minimumInterval) { seconds in
                update("Change Text Sequence") { $0.text?.sequence?.interval = min(seconds, TextSequence.maximumInterval) }
            }
            Toggle(L("Loop"), isOn: Binding(get: { sequence.loop }, set: { loop in update("Change Text Sequence") { $0.text?.sequence?.loop = loop } }))
            Button(L("Remove Text Sequence")) { update("Remove Text Sequence") { $0.text?.sequence = nil } }
        } else {
            Button(L("Add Text Sequence")) { update("Add Text Sequence") { $0.text?.sequence = Self.defaultSequence(text.content) } }
            Text(L("During playback, shows a list of texts in turn, such as a countdown."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The items typed one per line; blank lines at the end are dropped.
    static func items(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return Array(lines.prefix(TextSequence.maximumItems))
    }

    /// A countdown to 0 when the text is a whole number up to 999, otherwise the text itself.
    static func defaultSequence(_ content: String) -> TextSequence {
        guard let start = Int(content.trimmingCharacters(in: .whitespaces)), (1..<TextSequence.maximumItems).contains(start) else {
            return TextSequence(items: [content])
        }
        return TextSequence(items: (0...start).reversed().map(String.init))
    }

    private func animationSection(_ animation: LayerAnimation?) -> some View {
        Section(title: L("Animation")) {
            if let animation {
                let change = { (edit: @escaping (inout LayerAnimation) -> Void) in
                    update("Change Animation") { node in
                        guard var next = node.animation else { return }
                        edit(&next)
                        node.animation = next
                    }
                }
                Picker(L("Type|animation"), selection: Binding(get: { animation.type }, set: { type in
                    change { var next = LayerAnimation(type: type); next.delay = $0.delay; $0 = next }
                })) {
                    SwiftUI.Section(L("Entrance")) { ForEach(AnimationType.allCases.filter(\.isEntrance), id: \.self) { Text(Self.animationName($0)).tag($0) } }
                    SwiftUI.Section(L("Loop|animation")) { ForEach(AnimationType.allCases.filter { !$0.isEntrance }, id: \.self) { Text(Self.animationName($0)).tag($0) } }
                }
                if animation.type == .slideIn {
                    Picker(L("From|slide in"), selection: Binding(get: { animation.from }, set: { edge in change { $0.from = edge } })) {
                        Text(L("Left|edge")).tag(AnimationEdge.left)
                        Text(L("Right|edge")).tag(AnimationEdge.right)
                        Text(L("Top|edge")).tag(AnimationEdge.top)
                        Text(L("Bottom|edge")).tag(AnimationEdge.bottom)
                    }
                    NumberField(label: L("Distance"), value: animation.distance, minimum: 0) { v in change { $0.distance = min(v, LayerAnimation.maximumDistance) } }
                }
                if animation.type == .pulse {
                    Picker(L("Pulses"), selection: Binding(get: { animation.property }, set: { p in change { $0.property = p } })) {
                        Text(L("Scale|pulse")).tag(PulseProperty.scale)
                        Text(L("Opacity")).tag(PulseProperty.opacity)
                    }
                }
                NumberField(label: L("Duration (s)"), value: animation.duration, minimum: 0.01) { v in change { $0.duration = min(v, LayerAnimation.maximumDuration) } }
                NumberField(label: L("Delay (s)"), value: animation.delay, minimum: 0) { v in change { $0.delay = min(v, LayerAnimation.maximumDelay) } }
                Picker(L("Easing"), selection: Binding(get: { animation.easing }, set: { easing in change { $0.easing = easing } })) {
                    Text(L("Linear")).tag(TransitionEasing.linear)
                    Text(L("Ease In")).tag(TransitionEasing.easeIn)
                    Text(L("Ease Out")).tag(TransitionEasing.easeOut)
                    Text(L("Ease In and Out")).tag(TransitionEasing.easeInOut)
                }
                HStack {
                    Toggle(L("Repeat forever"), isOn: Binding(get: { animation.repeatCount == nil }, set: { forever in change { $0.repeatCount = forever ? nil : 1 } }))
                    if let count = animation.repeatCount {
                        NumberField(label: L("Times"), value: Double(count), minimum: 1) { v in
                            change { $0.repeatCount = min(max(Int(v.rounded()), 1), LayerAnimation.maximumRepeat) }
                        }
                    }
                }
                HStack {
                    Button(L("Preview")) { previewing = true }
                        .popover(isPresented: $previewing, arrowEdge: .bottom) { AnimationPreview(node: node) }
                    Button(L("Remove Animation")) { update("Remove Animation") { $0.animation = nil } }
                }
            } else {
                HStack {
                    Button(L("Add Animation")) { update("Add Animation") { $0.animation = LayerAnimation(type: .fadeIn) } }
                    if TextSequence.hasSequences(in: node) {
                        Button(L("Preview")) { previewing = true }
                            .popover(isPresented: $previewing, arrowEdge: .bottom) { AnimationPreview(node: node) }
                    }
                }
                Text(L("Plays when the layer's frame appears during playback: an entrance, or a loop such as a spinner."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func animationName(_ type: AnimationType) -> String {
        switch type {
        case .fadeIn: return L("Fade In")
        case .slideIn: return L("Slide In")
        case .scaleIn: return L("Scale In")
        case .spin: return L("Spin")
        case .pulse: return L("Pulse")
        case .shimmer: return L("Shimmer")
        }
    }

    static func weightName(_ weight: Int) -> String {
        [100: L("Thin"), 200: L("Extra Light"), 300: L("Light|font weight"), 400: L("Regular"), 500: L("Medium"), 600: L("Semibold"), 700: L("Bold"), 800: L("Extra Bold"), 900: L("Black")][weight] ?? "\(weight)"
    }

    private func layoutSection(_ layout: AutoLayout?) -> some View {
        Section(title: L("Auto Layout")) {
            if let layout {
                Picker(L("Direction"), selection: Binding(get: { layout.direction }, set: { v in update("Change Layout Direction") { $0.layout?.direction = v } })) {
                    Image(systemName: "arrow.down").accessibilityLabel(L("Vertical")).tag(LayoutDirection.vertical)
                    Image(systemName: "arrow.right").accessibilityLabel(L("Horizontal")).tag(LayoutDirection.horizontal)
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

    /// The top-level frames an interaction can go to; the frame holding this layer comes last, since going to it is rarely meant.
    private var destinations: [DesignNode] {
        let own = store.document.ancestry(of: node.id).first
        let frames = store.document.nodes.filter { $0.type == .frame }
        return frames.filter { $0.id != own } + frames.filter { $0.id == own }
    }

    /// The default destination: the first top-level frame other than the one holding this layer.
    private var otherFrame: String? {
        let own = store.document.ancestry(of: node.id).first
        return store.document.nodes.first { $0.type == .frame && $0.id != own }?.id
    }

    /// Layers a visibility toggle can show and hide: the others in the top-level frame holding this layer, depth first.
    private var toggleCandidates: [DesignNode] {
        guard let top = store.document.ancestry(of: node.id).first.flatMap({ store.document.node($0) }) else { return [] }
        var result: [DesignNode] = []
        DesignDocument(nodes: top.children).forEach { if $0.id != node.id { result.append($0) } }
        return result
    }

    /// Whether this layer sits directly in a frame that scrolls during playback.
    private var inScrollingFrame: Bool {
        guard let parent = store.document.parentID(of: node.id) ?? nil else { return false }
        return (store.document.node(parent)?.scroll ?? .none) != .none
    }

    private static func action(_ interaction: DesignInteraction) -> String {
        switch interaction {
        case .navigate: return "navigate"
        case .back: return "back"
        case .openOverlay: return "open-overlay"
        case .closeOverlay: return "close-overlay"
        case .toggleVisibility: return "toggle-visibility"
        }
    }

    /// The interaction a newly chosen action starts with; nil when it has nothing to point at.
    private func interaction(for action: String) -> DesignInteraction? {
        switch action {
        case "back": return .back
        case "close-overlay": return .closeOverlay
        case "navigate": return destinations.first.map { .navigate(destination: $0.id, transition: PrototypeTransition()) }
        case "open-overlay":
            // The frame holding the layer cannot be opened over itself.
            return otherFrame.map {
                .openOverlay(destination: $0, overlay: OverlaySettings(background: DesignColor(r: 0, g: 0, b: 0, a: 0.4)),
                             transition: PrototypeTransition(type: .dissolve))
            }
        default: return toggleCandidates.first.map { .toggleVisibility(targets: [$0.id]) }
        }
    }

    private func setInteraction(_ interaction: DesignInteraction) { update("Change Interaction") { $0.interaction = interaction } }

    private func interactionSection(_ interaction: DesignInteraction?) -> some View {
        Section(title: L("Prototype")) {
            if node.type == .frame {
                Picker(L("Scrolling"), selection: Binding(get: { node.scroll }, set: { v in update("Change Scrolling") { $0.scroll = v } })) {
                    Text(L("None|scrolling")).tag(ScrollDirection.none)
                    Text(L("Vertical")).tag(ScrollDirection.vertical)
                    Text(L("Horizontal")).tag(ScrollDirection.horizontal)
                }
            }
            if inScrollingFrame || node.fixedOnScroll {
                Toggle(L("Fix position when scrolling"), isOn: Binding(get: { node.fixedOnScroll }, set: { v in update("Change Scrolling") { $0.fixedOnScroll = v } }))
            }
            if let interaction {
                Text(L("On click")).foregroundStyle(.secondary)
                Picker(L("Action"), selection: Binding(get: { Self.action(interaction) }, set: { action in
                    if let next = self.interaction(for: action) { setInteraction(next) }
                })) {
                    Text(L("Navigate to|prototype")).tag("navigate")
                    Text(L("Back|prototype")).tag("back")
                    Text(L("Open Overlay")).tag("open-overlay")
                    Text(L("Close Overlay")).tag("close-overlay")
                    Text(L("Toggle Visibility")).tag("toggle-visibility")
                }
                switch interaction {
                case .navigate(let destination, let transition):
                    destinationPicker(destination) { .navigate(destination: $0, transition: transition) }
                    transitionControls(transition) { .navigate(destination: destination, transition: $0) }
                case .openOverlay(let destination, let overlay, let transition):
                    destinationPicker(destination) { .openOverlay(destination: $0, overlay: overlay, transition: transition) }
                    overlayControls(overlay) { .openOverlay(destination: destination, overlay: $0, transition: transition) }
                    transitionControls(transition) { .openOverlay(destination: destination, overlay: overlay, transition: $0) }
                case .toggleVisibility(let targets):
                    toggleControls(targets)
                case .back, .closeOverlay:
                    EmptyView()
                }
                Button(L("Remove Interaction")) { update("Remove Interaction") { $0.interaction = nil } }
            } else {
                Button(L("Add Interaction")) {
                    update("Add Interaction") { $0.interaction = otherFrame.map { .navigate(destination: $0, transition: PrototypeTransition()) } ?? .back }
                }
                Text(L("Clicking this layer during playback goes to another frame or back, opens or closes an overlay, or shows and hides layers."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            stateControls(L("While hovered"), L("Add Hover State"), node.states?.hover, key: "hover") { $0.hover = $1 }
            stateControls(L("While pressed"), L("Add Pressed State"), node.states?.pressed, key: "pressed") { $0.pressed = $1 }
        }
    }

    private func destinationPicker(_ destination: String, _ make: @escaping (String) -> DesignInteraction) -> some View {
        Picker(L("Destination"), selection: Binding(get: { destination }, set: { setInteraction(make($0)) })) {
            ForEach(destinations) { Text($0.name).tag($0.id) }
            if !destinations.contains(where: { $0.id == destination }) { Text(L("Missing frame")).tag(destination) }
        }
    }

    @ViewBuilder
    private func transitionControls(_ transition: PrototypeTransition, _ make: @escaping (PrototypeTransition) -> DesignInteraction) -> some View {
        Picker(L("Transition"), selection: Binding(get: { transition.type }, set: { type in
            var next = transition
            next.type = type
            setInteraction(make(next))
        })) {
            ForEach(TransitionType.allCases, id: \.self) { Text(Self.transitionName($0)).tag($0) }
        }
        if transition.type != .none {
            NumberField(label: L("Duration (s)"), value: transition.duration, minimum: 0) { seconds in
                var next = transition
                next.duration = min(seconds, PrototypeTransition.maximumDuration)
                setInteraction(make(next))
            }
            Picker(L("Easing"), selection: Binding(get: { transition.easing }, set: { easing in
                var next = transition
                next.easing = easing
                setInteraction(make(next))
            })) {
                Text(L("Linear")).tag(TransitionEasing.linear)
                Text(L("Ease In")).tag(TransitionEasing.easeIn)
                Text(L("Ease Out")).tag(TransitionEasing.easeOut)
                Text(L("Ease In and Out")).tag(TransitionEasing.easeInOut)
            }
        }
    }

    @ViewBuilder
    private func overlayControls(_ overlay: OverlaySettings, _ make: @escaping (OverlaySettings) -> DesignInteraction) -> some View {
        Picker(L("Position|overlay"), selection: Binding(get: { overlay.position }, set: { position in
            var next = overlay
            next.position = position
            setInteraction(make(next))
        })) {
            Text(L("Center|overlay position")).tag(OverlayPosition.center)
            Text(L("Bottom|overlay position")).tag(OverlayPosition.bottom)
            Text(L("Below Layer")).tag(OverlayPosition.belowTrigger)
        }
        if let background = overlay.background {
            HStack {
                ColorRow(label: L("Background"), color: background) { color in
                    var next = overlay
                    next.background = color
                    setInteraction(make(next))
                }
                Button {
                    var next = overlay
                    next.background = nil
                    setInteraction(make(next))
                } label: { Image(systemName: "minus").iconHitTarget() }
                    .buttonStyle(.borderless).help(L("Remove background")).accessibilityLabel(L("Remove background"))
            }
        } else {
            Button(L("Add Background")) {
                var next = overlay
                next.background = DesignColor(r: 0, g: 0, b: 0, a: 0.4)
                setInteraction(make(next))
            }
        }
        Toggle(L("Close when clicking outside"), isOn: Binding(get: { overlay.closeOnOutsideClick }, set: { value in
            var next = overlay
            next.closeOnOutsideClick = value
            setInteraction(make(next))
        }))
    }

    @ViewBuilder
    private func toggleControls(_ targets: [String]) -> some View {
        Text(L("Shows the hidden and hides the shown among:")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ForEach(targets, id: \.self) { id in
            HStack {
                Text(store.document.node(id)?.name ?? L("Missing layer")).lineLimit(1)
                Spacer()
                if targets.count > 1 {
                    Button { setInteraction(.toggleVisibility(targets: targets.filter { $0 != id })) } label: { Image(systemName: "minus").iconHitTarget() }
                        .buttonStyle(.borderless).help(L("Remove layer")).accessibilityLabel(L("Remove layer"))
                }
            }
        }
        let available = toggleCandidates.filter { !targets.contains($0.id) }
        Menu(L("Add Layer")) {
            ForEach(available) { candidate in
                Button(candidate.name) { setInteraction(.toggleVisibility(targets: targets + [candidate.id])) }
            }
        }
        .disabled(available.isEmpty)
    }

    /// One state's look: its own fill (or the layer's) and opacity, added and removed as a whole.
    private func changeState(_ action: String, _ key: String?, _ next: LayerStyle?, _ set: @escaping (inout LayerStates, LayerStyle?) -> Void) {
        update(action, key) { node in
            var states = node.states ?? LayerStates()
            set(&states, next)
            node.states = states == LayerStates() ? nil : states
        }
    }

    @ViewBuilder
    private func stateControls(_ title: String, _ add: String, _ style: LayerStyle?, key state: String,
                               _ set: @escaping (inout LayerStates, LayerStyle?) -> Void) -> some View {
        // Coalescing keys name the state, so hover and pressed edits stay separate undo steps.
        let change = { (action: String, key: String?, next: LayerStyle?) in changeState(action, key.map { $0.replacingOccurrences(of: "states.", with: "states.\(state).") }, next, set) }
        if let style {
            Text(title).foregroundStyle(.secondary)
            if let fill = style.fill {
                HStack {
                    ColorRow(label: L("Fill"), color: fill) { color in var next = style; next.fill = color; change("Change State", "states.fill", next) }
                    Button { var next = style; next.fill = nil; change("Change State", nil, next) } label: { Image(systemName: "minus").iconHitTarget() }
                        .buttonStyle(.borderless).help(L("Remove fill")).accessibilityLabel(L("Remove fill"))
                }
            } else {
                Button(L("Add Fill")) { var next = style; next.fill = node.fill ?? .white; change("Change State", nil, next) }
            }
            SliderRow(label: L("Opacity"), value: style.opacity ?? node.opacity) { value in
                var next = style
                next.opacity = value
                change("Change State", "states.opacity", next)
            }
            Button(L("Remove State")) { change("Remove State", nil, nil) }
        } else {
            Button(add) { change("Add State", nil, LayerStyle(opacity: 0.8)) }
        }
    }

    static func transitionName(_ type: TransitionType) -> String {
        switch type {
        case .none: return L("None|transition")
        case .dissolve: return L("Dissolve")
        case .pushLeft: return L("Push Left")
        case .pushRight: return L("Push Right")
        case .pushUp: return L("Push Up")
        case .pushDown: return L("Push Down")
        case .sheet: return L("Bottom Sheet")
        }
    }

    private func replaceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), DesignRenderer.imageSize(data) != nil else { return }
        update("Replace Image") { $0.image?.data = data }
    }
}
