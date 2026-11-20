import AppKit
import FudehandCore
import SwiftUI

/// Building blocks of the properties panel: sections, 28-point input boxes, number and color fields, and the auto layout
/// alignment grid. Layout: 16-point side margins, 8-point gaps, thin dividers between sections.
enum InspectorMetrics {
    static let margin: CGFloat = 16
    static let fieldHeight: CGFloat = 28
    static let gap: CGFloat = 8
}

/// A titled block of the panel, followed by a divider. `accessory` sits at the right end of the title row.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.gap) {
            HStack(spacing: InspectorMetrics.gap) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: 20)
            content
        }
        .font(.system(size: 12))
        .padding(.horizontal, InspectorMetrics.margin).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

extension InspectorSection where Content == EmptyView {
    /// An empty section folded down to its title row, whose `+` adds the property.
    init(_ title: String, adding label: String, add: @escaping () -> Void) where Accessory == AddButton {
        self.init(title, accessory: { AddButton(label: label, action: add) }, content: { EmptyView() })
    }
}

struct AddButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "plus").font(.system(size: 11)).iconHitTarget() }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

/// A trailing remove button, sized and placed to line up with the other rows of a section.
struct RemoveButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "minus").font(.system(size: 11)).iconHitTarget() }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

/// The rounded 28-point box every inline input sits in.
struct FieldBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: InspectorMetrics.fieldHeight, maxHeight: InspectorMetrics.fieldHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
    }
}

/// The layer the inspector shows; fields that hold a draft reset it when this changes.
private struct InspectedLayerKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var inspectedLayer: String? {
        get { self[InspectedLayerKey.self] }
        set { self[InspectedLayerKey.self] = newValue }
    }
}

/// A bare number text field, committed on Return or when focus is lost. A percent field shows and types a 0–1 value as 0–100%.
struct NumberText: View {
    let label: String
    let value: Double
    var minimum: Double? = nil
    var percent = false
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.inspectedLayer) private var layer
    /// The layer the text was typed for. A draft typed for the previous layer is dropped, never committed to the newly
    /// selected one, whichever order SwiftUI reports the focus loss and the layer change in.
    @State private var draftLayer: String?

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.plain).monospacedDigit().focused($focused)
            .onSubmit(submit)
            .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
            .accessibilityLabel(label)
            .onAppear { text = display(value); draftLayer = layer }
            .onChange(of: value) { _, next in if !focused { text = display(next) } }
            .onChange(of: layer) { text = display(value); draftLayer = layer }
    }

    private func display(_ value: Double) -> String { percent ? NumberInput.formatPercent(value) : NumberInput.format(value) }

    private func submit() {
        guard draftLayer == layer else { text = display(value); draftLayer = layer; return }
        let next = percent ? NumberInput.committedPercent(text: text, current: value)
            : NumberInput.committedValue(text: text, current: value, minimum: minimum)
        if let next { commit(next) }
        text = display(next ?? value)
    }
}

/// A number input in a box, led by a short caption or an icon. With `scrub`, dragging the caption sideways changes the
/// value by `scrub` per point; the caller coalesces the edits, so a continuous drag is one undo step.
struct NumberField: View {
    let label: String
    var caption: String? = nil
    var symbol: String? = nil
    let value: Double
    var minimum: Double? = nil
    var percent = false
    var scrub: Double? = nil
    var disabled = false
    var accessory: AnyView? = nil
    let commit: (Double) -> Void
    @State private var scrubStart: Double?
    @State private var hovering = false
    /// Whether this field pushed the resize cursor; it is popped exactly once, also when the view goes away mid-hover.
    @State private var cursorPushed = false

    var body: some View {
        FieldBox {
            lead
                .foregroundStyle(.secondary)
                .gesture(scrubGesture, including: scrub == nil ? .none : .all)
                .onHover { inside in hovering = inside; updateCursor() }
                .onDisappear { hovering = false; scrubStart = nil; updateCursor() }
            NumberText(label: label, value: value, minimum: minimum, percent: percent, commit: commit)
            if let accessory { accessory }
        }
        .disabled(disabled)
    }

    /// The resize cursor shows while the caption is hovered or being dragged, even after the pointer leaves it.
    private func updateCursor() {
        let wanted = scrub != nil && !disabled && (hovering || scrubStart != nil)
        if wanted && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
        if !wanted && cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    @ViewBuilder private var lead: some View {
        if let symbol {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 14).accessibilityHidden(true)
        } else {
            Text(caption ?? label).font(.system(size: 11)).lineLimit(1).fixedSize().accessibilityHidden(true)
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                guard let scrub else { return }
                let start = scrubStart ?? value
                scrubStart = start
                let low = percent ? 0 : (minimum ?? -DesignJSON.maximumMagnitude)
                let high = percent ? 1 : DesignJSON.maximumMagnitude
                var next = start + Double(drag.translation.width) * scrub
                if !percent { next = next.rounded() }
                next = min(high, max(low, (next * 100).rounded() / 100))
                if next != value { commit(next) }
            }
            .onEnded { _ in scrubStart = nil; updateCursor() }
    }
}

extension DesignColor {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

/// A color in a box: swatch (opens the color picker), six-digit hex, and opacity; with `remove`, a trailing remove button.
struct ColorField: View {
    let label: String
    let color: DesignColor
    var removeLabel: String? = nil
    var remove: (() -> Void)? = nil
    let commit: (DesignColor) -> Void
    @State private var hex = ""
    @FocusState private var hexFocused: Bool
    @Environment(\.inspectedLayer) private var layer

    var body: some View {
        HStack(spacing: InspectorMetrics.gap) {
            FieldBox {
                ColorPicker(label, selection: Binding(get: { color.swiftUI }, set: { commit(DesignColor($0)) }), supportsOpacity: true)
                    .labelsHidden().controlSize(.mini).frame(width: 22)
                TextField(L("Hex"), text: $hex).textFieldStyle(.plain).monospaced().focused($hexFocused)
                    .onSubmit(submitHex)
                    .onChange(of: hexFocused) { _, isFocused in if !isFocused { submitHex() } }
                    .accessibilityLabel(L("%@ hex", label))
                NumberText(label: L("%@ opacity", label), value: color.a, percent: true) { alpha in
                    var next = color
                    next.a = alpha
                    commit(next)
                }
                .multilineTextAlignment(.trailing).frame(width: 40)
            }
            if let remove, let removeLabel { RemoveButton(label: removeLabel, action: remove) }
        }
        .onAppear { hex = HexInput.text(color) }
        .onChange(of: color) { _, next in hex = HexInput.text(next) }
        .onChange(of: layer) { hex = HexInput.text(color) }
    }

    private func submitHex() {
        if let next = HexInput.committedColor(text: hex, current: color) { commit(next) }
        hex = HexInput.text(color)
    }
}

/// The 3×3 auto layout alignment grid; its rules are in `AlignmentGrid`.
struct AlignmentGridView: View {
    let layout: AutoLayout
    let commit: (AutoLayout) -> Void
    static let side: CGFloat = 92

    private static let names = [
        [L("Top left"), L("Top center"), L("Top right")],
        [L("Center left"), L("Center"), L("Center right")],
        [L("Bottom left"), L("Bottom center"), L("Bottom right")],
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { column in cell(row, column) }
                }
            }
        }
        .padding(4)
        .frame(width: Self.side, height: Self.side)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        .disabled(!AlignmentGrid.isAvailable(layout))
        .accessibilityElement(children: .contain).accessibilityLabel(L("Alignment"))
    }

    private func cell(_ row: Int, _ column: Int) -> some View {
        // With both axes held there is nothing to choose, so no cell is drawn as chosen.
        let selected = AlignmentGrid.isAvailable(layout) && AlignmentGrid.isSelected(row: row, column: column, in: layout)
        return Button { commit(AlignmentGrid.choosing(row: row, column: column, in: layout)) } label: {
            RoundedRectangle(cornerRadius: selected ? 2 : 1.5)
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: selected ? 10 : 3, height: selected ? 10 : 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.names[row][column]).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An on/off switch drawn as a 28-point box with an icon and a label, tinted while on.
struct BoxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(configuration.isOn ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: InspectorMetrics.fieldHeight, maxHeight: InspectorMetrics.fieldHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isOn ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// The sizing mode chip inside a W or H box: a short name that opens the menu of modes.
struct SizingChip: View {
    let label: String
    let mode: SizingMode
    let commit: (SizingMode) -> Void

    var body: some View {
        Menu {
            Picker(label, selection: Binding(get: { mode }, set: commit)) {
                Text(L("Fixed")).tag(SizingMode.fixed)
                Text(L("Hug contents")).tag(SizingMode.hug)
                Text(L("Fill container")).tag(SizingMode.fill)
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(Self.shortName(mode)).font(.system(size: 10))
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .help(label).accessibilityLabel(label).accessibilityValue(Self.shortName(mode))
    }

    static func shortName(_ mode: SizingMode) -> String {
        switch mode {
        case .fixed: return L("Fixed")
        case .hug: return L("Hug|sizing")
        case .fill: return L("Fill|sizing")
        }
    }
}
