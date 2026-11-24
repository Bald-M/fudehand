import AppKit
import FudehandCore
import SwiftUI

/// The Insert Component popover: the document's main components by name with a small preview, searchable. Choosing one
/// inserts an instance of it (see "Components" in `docs/macos.md`).
struct ComponentPicker: View {
    let components: [DesignNode]
    let choose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var previews: [String: CGImage] = [:]
    @FocusState private var searchFocused: Bool

    private static let previewSide = 40.0

    private var shown: [DesignNode] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? components : components.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Search Components"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "diamond").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text(L("No Components")).font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { component in
                            ComponentRow(name: component.name, preview: previews[component.id]) {
                                choose(component.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280, height: 360)
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss() }
        .task {
            for component in components where previews[component.id] == nil {
                let side = max(component.width, component.height)
                guard side > 0 else { continue }
                let scale = Self.previewSide * 2 / side
                let rect = CGRect(x: 0, y: 0, width: component.width, height: component.height)
                previews[component.id] = try? DesignRenderer.image(of: component, in: rect, scale: scale)
                await Task.yield()
            }
        }
    }
}

private struct ComponentRow: View {
    let name: String
    let preview: CGImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let preview {
                        Image(decorative: preview, scale: 2).resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Text(name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
