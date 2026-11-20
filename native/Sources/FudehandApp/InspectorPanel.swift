import AppKit
import FudehandCore
import SwiftUI

/// The inspector on the right: the "Design" tab edits the selected layers' look and layout, the "Prototype" tab their
/// interaction, states, scrolling, and animation, and the "Chat" tab is the Agent chat panel.
struct InspectorPanel: View {
    @ObservedObject var store: FudehandStore
    @ObservedObject var selection: LayerSelection

    init(store: FudehandStore) {
        self.store = store
        selection = store.layerSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabs(selection: $store.inspectorTab)
            Divider()
            switch store.inspectorTab {
            case .design, .prototype: DesignInspector(store: store, selection: selection, page: store.inspectorTab)
            case .chat:
                let selected = selection.ids.compactMap { store.document.node($0) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                ChatPanel(chat: store.chat, root: store.toolsRoot, runtime: store.runtime,
                          selection: selected.map { ChatContext(id: $0.id, name: $0.name, type: $0.type.rawValue) },
                          layerName: { store.document.node($0)?.name })
            }
        }
    }
}

/// The tab row at the top of the inspector: text tabs, the selected one emphasized.
private struct InspectorTabs: View {
    @Binding var selection: InspectorTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Text(Self.title(tab))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 8).frame(height: InspectorMetrics.fieldHeight)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 44)
        .accessibilityElement(children: .contain).accessibilityLabel(L("Inspector"))
    }

    static func title(_ tab: InspectorTab) -> String {
        switch tab {
        case .design: return L("Design")
        case .prototype: return L("Prototype")
        case .chat: return L("Chat")
        }
    }
}

private struct DesignInspector: View {
    @ObservedObject var store: FudehandStore
    @ObservedObject var selection: LayerSelection
    let page: InspectorTab

    var body: some View {
        let selected = selection.ids.compactMap { store.document.node($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if selected.count == 1, let node = selected.first {
                    // Kept when the selection moves to another layer, instead of rebuilt: rebuilding every control took most of the
                    // time of a selection change (#142). Fields reset their drafts on `inspectedLayer` instead.
                    NodeInspector(store: store, node: node, parentLayout: parentLayout(of: node.id), page: page).environment(\.inspectedLayer, node.id)
                } else if selected.count > 1 && page == .design {
                    InspectorSection(L("%d layers selected", selected.count)) {
                        HStack(spacing: InspectorMetrics.gap) {
                            NumberField(label: L("Opacity"), symbol: "circle.lefthalf.filled", value: selected.map(\.opacity).reduce(0, +) / Double(selected.count),
                                        percent: true, scrub: 0.01) { value in
                                store.edit("Change Opacity", coalescing: "\(selected.map(\.id).sorted().joined(separator: ",")).opacity") { document in
                                    for node in selected { try document.update(node.id) { $0.opacity = value } }
                                }
                            }
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                    // A typed draft belongs to this set of layers and is dropped when the selection changes.
                    .environment(\.inspectedLayer, selected.map(\.id).sorted().joined(separator: ","))
                } else if selected.count > 1 {
                    InspectorSection(L("%d layers selected", selected.count)) {
                        Text(L("Select one layer to edit its prototype settings."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    InspectorSection(L("Document")) {
                        LabeledContent(L("Name"), value: store.title)
                        LabeledContent(L("Layers"), value: "\(store.document.nodeCount)")
                        Text(page == .design ? L("Select a layer to edit its position, size, fill, stroke, text, and auto layout here.")
                                             : L("Select a layer to edit its interaction, states, scrolling, and animation here."))
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

private struct NodeInspector: View {
    @ObservedObject var store: FudehandStore
    let node: DesignNode
    let parentLayout: AutoLayout?
    let page: InspectorTab
    @State private var name = ""
    @State private var content = ""
    /// The text sequence's items, one per line.
    @State private var sequenceItems = ""
    @State private var previewing = false
    @State private var replacingIcon = false
    /// The draft of a version snapshot's note.
    @State private var note = ""

    private func update(_ action: String, _ key: String? = nil, _ change: @escaping (inout DesignNode) -> Void) {
        store.updateNode(node.id, action, coalescing: key) { change(&$0) }
    }

    var body: some View {
        header
        if page == .prototype {
            interactionSection(node.interaction)
            animationSection(node.animation)
        } else {
            designPage
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: InspectorMetrics.gap) {
                Image(systemName: node.layout != nil ? "square.split.1x2" : node.type.symbol)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    TextField(L("Name"), text: $name).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .onSubmit { let trimmed = name.trimmingCharacters(in: .whitespaces); if !trimmed.isEmpty { update("Rename Layer") { $0.name = trimmed } } }
                        .onAppear { name = node.name }
                        .onChange(of: node.name) { _, next in name = next }
                        .onChange(of: node.id) { name = node.name; content = node.text?.content ?? ""; note = node.versionSnapshot?.note ?? ""; previewing = false }
                        .accessibilityLabel(L("Layer name"))
                    Text(node.type.title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { update(node.visible ? "Hide Layer" : "Show Layer") { $0.visible.toggle() } } label: {
                    Image(systemName: node.visible ? "eye" : "eye.slash").font(.system(size: 12)).iconHitTarget()
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help(node.visible ? L("Hide") : L("Show")).accessibilityLabel(node.visible ? L("Hide %@", node.name) : L("Show %@", node.name))
            }
            .padding(.horizontal, InspectorMetrics.margin).padding(.vertical, 12)
            Divider()
        }
    }

    @ViewBuilder private var designPage: some View {
        InspectorSection(L("Position and Size")) {
            let inLayout = parentLayout != nil
            // A group's size always equals the union of its child layers, so sizing modes have no effect on it (#60).
            let sizing = node.type != .group && (inLayout || node.layout != nil || node.type == .text)
            HStack(spacing: InspectorMetrics.gap) {
                NumberField(label: "X", value: node.x, disabled: inLayout) { v in update("Change Position") { $0.x = v } }
                NumberField(label: "Y", value: node.y, disabled: inLayout) { v in update("Change Position") { $0.y = v } }
            }
            HStack(spacing: InspectorMetrics.gap) {
                NumberField(label: "W", value: node.width, minimum: 0, disabled: node.type == .group,
                            accessory: sizing ? AnyView(SizingChip(label: L("Width"), mode: node.sizing.horizontal) { mode in update("Change Sizing") { $0.sizing.horizontal = mode } }) : nil) { v in
                    update("Change Size") { $0.width = v; $0.sizing.horizontal = .fixed; if $0.text?.autoResize == .widthAndHeight { $0.text?.autoResize = .height } }
                }
                NumberField(label: "H", value: node.height, minimum: 0, disabled: node.type == .group,
                            accessory: sizing ? AnyView(SizingChip(label: L("Height"), mode: node.sizing.vertical) { mode in update("Change Sizing") { $0.sizing.vertical = mode } }) : nil) { v in
                    update("Change Size") { $0.height = v; $0.sizing.vertical = .fixed; if $0.text != nil { $0.text?.autoResize = .none } }
                }
            }
        }
        if node.type == .frame { layoutSection(node.layout) }
        InspectorSection(L("Appearance")) {
            HStack(spacing: InspectorMetrics.gap) {
                NumberField(label: L("Opacity"), symbol: "circle.lefthalf.filled", value: node.opacity, percent: true, scrub: 0.01) { v in
                    update("Change Opacity", "opacity") { $0.opacity = v }
                }
                if node.type.hasCornerRadius {
                    NumberField(label: L("Corner radius"), symbol: "square.dashed", value: node.cornerRadius, minimum: 0) { v in
                        update("Change Corner Radius") { $0.cornerRadius = v }
                    }
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
            }
        }
        let fillTitle = node.type == .text ? L("Background") : L("Fill")
        if let fill = node.fill {
            InspectorSection(fillTitle) {
                ColorField(label: fillTitle, color: fill, removeLabel: L("Remove fill"), remove: { update("Remove Fill") { $0.fill = nil } }) { c in
                    update("Change Fill", "fill") { $0.fill = c }
                }
            }
        } else {
            InspectorSection(fillTitle, adding: L("Add Fill")) { update("Add Fill") { $0.fill = .white } }
        }
        if let stroke = node.stroke {
            InspectorSection(L("Stroke")) {
                ColorField(label: L("Stroke"), color: stroke.color, removeLabel: L("Remove stroke"), remove: { update("Remove Stroke") { $0.stroke = nil } }) { c in
                    update("Change Stroke", "stroke") { $0.stroke?.color = c }
                }
                HStack(spacing: InspectorMetrics.gap) {
                    NumberField(label: L("Weight|stroke"), value: stroke.width, minimum: 0) { v in update("Change Stroke") { $0.stroke?.width = v } }
                    // Lines the box up with the color box above, which leaves room for the remove button.
                    Color.clear.frame(width: 20, height: 1)
                }
            }
        } else {
            InspectorSection(L("Stroke"), adding: L("Add Stroke")) { update("Add Stroke") { $0.stroke = DesignStroke(color: .black, width: 1) } }
        }
        if node.type.hasEffects { EffectsSection(node: node, update: update) }
        if let text = node.text { textSection(text) }
        if let image = node.image {
            InspectorSection(L("Image")) {
                Picker(L("Scaling"), selection: Binding(get: { image.fit }, set: { v in update("Change Image Scaling") { $0.image?.fit = v } })) {
                    Text(L("Fill|image scaling")).tag(ImageFit.fill)
                    Text(L("Fit|image scaling")).tag(ImageFit.fit)
                    Text(L("Stretch")).tag(ImageFit.stretch)
                }
                // A version snapshot's picture is what the frame looked like; replacing it would contradict its record.
                if node.versionSnapshot == nil { Button(L("Replace Image…")) { replaceImage() } }
            }
        }
        if let icon = node.icon {
            InspectorSection(L("Icon")) {
                LabeledContent(L("Icon name")) { Text(icon.name).textSelection(.enabled).monospaced() }
                ColorField(label: L("Icon color"), color: icon.color) { c in update("Change Icon Color", "icon.color") { $0.icon?.color = c } }
                Button(L("Replace Icon…")) { replacingIcon = true }
                    .popover(isPresented: $replacingIcon, arrowEdge: .leading) {
                        IconPicker(current: icon.name) { store.replaceIcon(node.id, with: $0) }
                    }
            }
        }
        if let snapshot = node.versionSnapshot { versionSnapshotSection(snapshot) }
        if node.type == .frame { frameSnapshotsSection }
    }

    private static let snapshotTime = Date.FormatStyle.dateTime.year().month().day().hour().minute()

    /// A frame's version snapshots, oldest first: choosing one selects it and brings it into view.
    private var frameSnapshotsSection: some View {
        InspectorSection(L("Version Snapshots")) {
            ForEach(store.document.versionSnapshots(of: node.id)) { layer in
                if let snapshot = layer.versionSnapshot {
                    Button { store.setSelection([layer.id]); store.focus(layer.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.createdAt, format: Self.snapshotTime)
                            if !snapshot.note.isEmpty { Text(snapshot.note).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(L("Save Version Snapshot")) { store.saveVersionSnapshotOfSelection() }
        }
    }

    /// A version snapshot's frame, time, and note, and the switch between laying it over its frame and placing it beside.
    private func versionSnapshotSection(_ snapshot: VersionSnapshot) -> some View {
        let frame = store.document.worldRect(snapshot.frame)
        let here = store.document.worldRect(node.id)
        let overlaid = frame.map { frame in here.map { abs($0.x - frame.x) < 0.5 && abs($0.y - frame.y) < 0.5 } ?? false } ?? false
        return InspectorSection(L("Version Snapshot")) {
            LabeledContent(L("Frame")) { Text(store.document.node(snapshot.frame)?.name ?? L("Deleted")) }
            LabeledContent(L("Saved|version snapshot time")) { Text(snapshot.createdAt, format: Self.snapshotTime) }
            TextField(L("Note"), text: $note).textFieldStyle(.roundedBorder)
                .onSubmit { update("Edit Snapshot Note") { $0.versionSnapshot?.note = note.trimmingCharacters(in: .whitespacesAndNewlines) } }
                .onAppear { note = snapshot.note }
                .onChange(of: snapshot.note) { _, next in note = next }
                .accessibilityLabel(L("Snapshot note"))
            if frame != nil {
                Button(overlaid ? L("Place Beside Frame") : L("Overlay on Frame")) { store.compareVersionSnapshot(node.id, overlay: !overlaid) }
            }
        }
    }

    private func textSection(_ text: DesignText) -> some View {
        InspectorSection(L("Text")) {
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
            HStack(spacing: InspectorMetrics.gap) {
                NumberField(label: L("Font size"), symbol: "textformat.size", value: text.fontSize, minimum: 1) { v in update("Change Font Size") { $0.text?.fontSize = v } }
                Picker(L("Weight|font"), selection: Binding(get: { text.fontWeight }, set: { v in update("Change Font Weight") { $0.text?.fontWeight = v } })) {
                    ForEach([100, 200, 300, 400, 500, 600, 700, 800, 900], id: \.self) { Text(Self.weightName($0)).tag($0) }
                }.labelsHidden()
            }
            ColorField(label: L("Text color"), color: text.color) { c in update("Change Text Color", "text.color") { $0.text?.color = c } }
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
        InspectorSection(L("Animation")) {
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

    private func setLayout(_ action: String, _ next: AutoLayout) { update(action) { $0.layout = next } }

    private func layoutSection(_ layout: AutoLayout?) -> some View {
        InspectorSection(L("Auto Layout")) {
            if layout != nil {
                Button(L("Remove")) { update("Remove Auto Layout") { $0.layout = nil } }
                    .buttonStyle(.borderless).font(.system(size: 11)).help(L("Remove Auto Layout")).accessibilityLabel(L("Remove Auto Layout"))
            } else {
                AddButton(label: L("Add Auto Layout")) { update("Add Auto Layout") { $0.layout = AutoLayout(direction: .vertical, spacing: 8) } }
            }
        } content: {
            if let layout {
                Picker(L("Direction"), selection: Binding(get: { layout.direction }, set: { v in update("Change Layout Direction") { $0.layout?.direction = v } })) {
                    Label(L("Vertical"), systemImage: "arrow.down").tag(LayoutDirection.vertical)
                    Label(L("Horizontal"), systemImage: "arrow.right").tag(LayoutDirection.horizontal)
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(alignment: .top, spacing: InspectorMetrics.gap) {
                    AlignmentGridView(layout: layout) { setLayout("Change Alignment", $0) }
                    VStack(spacing: 4) {
                        NumberField(label: L("Gap"), value: layout.spacing) { v in update("Change Spacing") { $0.layout?.spacing = v } }
                        // Each holds one axis of the grid: space between the main axis, stretch the cross axis.
                        let horizontal = layout.direction == .horizontal
                        Toggle(isOn: Binding(get: { layout.align == .spaceBetween }, set: { setLayout("Change Alignment", AlignmentGrid.settingSpaceBetween($0, in: layout)) })) {
                            Label(L("Space between"), systemImage: horizontal ? "arrow.left.and.right" : "arrow.up.and.down")
                        }
                        Toggle(isOn: Binding(get: { layout.crossAlign == .stretch }, set: { setLayout("Change Alignment", AlignmentGrid.settingStretch($0, in: layout)) })) {
                            Label(L("Stretch"), systemImage: horizontal ? "arrow.up.and.down" : "arrow.left.and.right")
                        }
                    }
                    .toggleStyle(BoxToggleStyle())
                }
                Text(L("Padding")).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    NumberField(label: L("Top"), caption: L("T|padding"), value: layout.padding.top, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.top = v } }
                    NumberField(label: L("Right"), caption: L("R|padding"), value: layout.padding.right, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.right = v } }
                    NumberField(label: L("Bottom"), caption: L("B|padding"), value: layout.padding.bottom, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.bottom = v } }
                    NumberField(label: L("Left"), caption: L("L|padding"), value: layout.padding.left, minimum: 0) { v in update("Change Padding") { $0.layout?.padding.left = v } }
                }
            }
            Toggle(L("Clip content"), isOn: Binding(get: { node.clipsContent }, set: { v in update("Change Clipping") { $0.clipsContent = v } }))
                .toggleStyle(.checkbox)
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

    private func setInteraction(_ interaction: DesignInteraction, coalescing key: String? = nil) {
        update("Change Interaction", key) { $0.interaction = interaction }
    }

    private func interactionSection(_ interaction: DesignInteraction?) -> some View {
        InspectorSection(L("Prototype")) {
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
            ColorField(label: L("Background"), color: background, removeLabel: L("Remove background"), remove: {
                var next = overlay
                next.background = nil
                setInteraction(make(next))
            }) { color in
                var next = overlay
                next.background = color
                // A drag in the color picker is one undo step.
                setInteraction(make(next), coalescing: "interaction.overlay.background")
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
                ColorField(label: L("Fill"), color: fill, removeLabel: L("Remove fill"), remove: { var next = style; next.fill = nil; change("Change State", nil, next) }) { color in
                    var next = style
                    next.fill = color
                    change("Change State", "states.fill", next)
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

/// The layer's effects: one row per effect, the frontmost at the top like the layers panel, each with its type, settings that
/// expand below it, show or hide, and remove; a row's context menu moves it. Empty, the section folds to its title row and `+`.
private struct EffectsSection: View {
    let node: DesignNode
    let update: (String, String?, @escaping (inout DesignNode) -> Void) -> Void
    /// The rows whose settings are shown, by effect index.
    @State private var expanded: Set<Int> = []
    /// The effect count this view's own add or remove leads to; any other change to the count (undo, the Agent) collapses
    /// every row, since the indexes no longer name the same effects.
    @State private var expectedCount: Int?
    @Environment(\.inspectedLayer) private var layer

    var body: some View {
        InspectorSection(L("Effects"), accessory: { addMenu }) {
            if !node.effects.isEmpty {
                ForEach(node.effects.indices.reversed(), id: \.self) { index in row(index, node.effects[index]) }
            }
        }
        .onChange(of: layer) { expanded = []; expectedCount = nil }
        .onChange(of: node.effects.count) { _, count in
            if count != expectedCount { expanded = [] }
            expectedCount = nil
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(EffectType.allCases, id: \.self) { type in
                Button(Self.name(type)) {
                    let index = node.effects.count
                    expectedCount = index + 1
                    update("Add Effect", nil) { $0.effects.append(DesignEffect(type: type)) }
                    expanded.insert(index)
                }
            }
        } label: { MenuIcon(symbol: "plus", label: L("Add Effect")) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Add Effect")).accessibilityLabel(L("Add Effect"))
    }

    @ViewBuilder private func row(_ index: Int, _ effect: DesignEffect) -> some View {
        let change = { (edit: @escaping (inout DesignEffect) -> Void) in
            update("Change Effect", nil) { node in if node.effects.indices.contains(index) { edit(&node.effects[index]) } }
        }
        let open = expanded.contains(index)
        HStack(spacing: 4) {
            Button { if open { expanded.remove(index) } else { expanded.insert(index) } } label: {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 11)).iconHitTarget()
            }
            .buttonStyle(.borderless)
            .help(open ? L("Hide effect settings") : L("Show effect settings"))
            .accessibilityLabel(open ? L("Hide effect settings") : L("Show effect settings"))
            Picker(L("Effect type"), selection: Binding(get: { effect.type }, set: { type in
                change { current in
                    guard current.type != type else { return }
                    var next = current.type.isShadow && type.isShadow ? current : DesignEffect(type: type)
                    next.type = type
                    next.visible = current.visible
                    current = next
                }
            })) {
                ForEach(EffectType.allCases, id: \.self) { Text(Self.name($0)).tag($0) }
            }
            .labelsHidden()
            Button { change { $0.visible.toggle() } } label: {
                Image(systemName: effect.visible ? "eye" : "eye.slash").font(.system(size: 11)).iconHitTarget()
            }
            .buttonStyle(.borderless)
            .help(effect.visible ? L("Hide effect") : L("Show effect"))
            .accessibilityLabel(effect.visible ? L("Hide effect") : L("Show effect"))
            RemoveButton(label: L("Remove effect")) {
                expectedCount = node.effects.count - 1
                update("Remove Effect", nil) { if $0.effects.indices.contains(index) { $0.effects.remove(at: index) } }
                expanded = Set(expanded.compactMap { $0 < index ? $0 : $0 > index ? $0 - 1 : nil })
            }
        }
        .contextMenu {
            // Up brings the effect forward, drawn later.
            Button(L("Move Up")) { move(index, by: 1) }.disabled(index == node.effects.count - 1)
            Button(L("Move Down")) { move(index, by: -1) }.disabled(index == 0)
        }
        if open {
            VStack(alignment: .leading, spacing: InspectorMetrics.gap) {
                if effect.type.isShadow {
                    ColorField(label: L("Shadow color"), color: effect.color) { c in
                        update("Change Effect", "effects.\(index).color") { node in if node.effects.indices.contains(index) { node.effects[index].color = c } }
                    }
                    HStack(spacing: InspectorMetrics.gap) {
                        NumberField(label: "X", value: effect.x) { v in change { $0.x = v } }
                        NumberField(label: "Y", value: effect.y) { v in change { $0.y = v } }
                    }
                }
                HStack(spacing: InspectorMetrics.gap) {
                    NumberField(label: L("Blur"), value: effect.radius, minimum: 0) { v in change { $0.radius = min(v, DesignEffect.maximumRadius) } }
                    // Text and icon shadows follow the glyphs, which spread does not grow.
                    if effect.type.isShadow, node.type != .text, node.type != .icon {
                        NumberField(label: L("Spread"), value: effect.spread) { v in change { $0.spread = v } }
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.leading, 20)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard node.effects.indices.contains(target) else { return }
        update("Reorder Effects", nil) { node in
            guard node.effects.indices.contains(index), node.effects.indices.contains(target) else { return }
            node.effects.swapAt(index, target)
        }
        let wasOpen = expanded.contains(index), otherOpen = expanded.contains(target)
        expanded.remove(index); expanded.remove(target)
        if wasOpen { expanded.insert(target) }
        if otherOpen { expanded.insert(index) }
    }

    static func name(_ type: EffectType) -> String {
        switch type {
        case .dropShadow: return L("Drop Shadow")
        case .innerShadow: return L("Inner Shadow")
        case .layerBlur: return L("Layer Blur")
        case .backgroundBlur: return L("Background Blur")
        }
    }
}
