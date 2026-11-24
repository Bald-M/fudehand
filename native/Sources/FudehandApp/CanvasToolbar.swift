import FudehandCore
import SwiftUI

/// The bar floating over the bottom of the canvas: the canvas tools, Insert Image, the icon picker, and the component picker.
struct CanvasToolbar: View {
    @ObservedObject var store: FudehandStore
    @State private var pickingIcon = false
    @State private var pickingComponent = false

    /// Tool, name key, shortcut key, symbol.
    static let tools: [(CanvasTool, String, String, String)] = [
        (.move, "Move", "V", "cursorarrow"), (.hand, "Hand", "H", "hand.raised"), (.frame, "Frame", "F", "number"),
        (.rectangle, "Rectangle", "R", "rectangle"), (.ellipse, "Ellipse", "O", "circle"), (.text, "Text", "T", "t.square"),
        (.annotate, "Annotate", "C", "text.bubble"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.tools, id: \.0) { tool, name, key, symbol in
                ToolButton(title: "\(L(name)) \(key)", symbol: symbol, selected: store.tool == tool) { store.tool = tool }
            }
            Divider().frame(height: 20).padding(.horizontal, 4)
            ToolButton(title: L("Insert Image"), symbol: "photo.badge.plus", selected: false) { store.insertImage() }
            ToolButton(title: L("Insert Icon"), symbol: "star.square.on.square", selected: pickingIcon) { pickingIcon = true }
                .popover(isPresented: $pickingIcon, arrowEdge: .top) { IconPicker(current: nil) { store.insertIcon($0) } }
            ToolButton(title: L("Insert Component"), symbol: "plus.diamond", selected: pickingComponent) { pickingComponent = true }
                .popover(isPresented: $pickingComponent, arrowEdge: .top) {
                    ComponentPicker(components: store.listComponents().map(\.component)) { store.insertComponent($0) }
                }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .accessibilityElement(children: .contain).accessibilityLabel(L("Canvas tools"))
    }
}

private struct ToolButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15))
                .frame(width: 32, height: 32)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(hovering ? 0.1 : 0)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
