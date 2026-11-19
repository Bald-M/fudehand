import AppKit
import FudehandCore
import SwiftUI

/// The icon picker: switch between the built-in icon libraries, search by keyword, and choose an icon from a grid. The bottom
/// toolbar opens it to insert an icon layer, and the inspector to replace the icon of the selected one.
struct IconPicker: View {
    /// The libraries as the picker groups them: Material Symbols is one entry with a style menu.
    enum Family: CaseIterable, Hashable {
        case sf, material, weui, lucide

        var title: String {
            switch self {
            case .sf: return "SF Symbols"
            case .material: return "Material Symbols"
            case .weui: return "WeUI"
            case .lucide: return "Lucide"
            }
        }
    }

    let current: String?
    let choose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var family: Family
    @State private var materialStyle: IconLibrary
    @State private var query = ""
    @State private var results: [String] = []
    @State private var loaded = false
    @FocusState private var searchFocused: Bool

    init(current: String?, choose: @escaping (String) -> Void) {
        self.current = current
        self.choose = choose
        let library = current.flatMap { IconLibrary.parse($0)?.library } ?? .sf
        switch library {
        case .sf: _family = State(initialValue: .sf)
        case .weui: _family = State(initialValue: .weui)
        case .lucide: _family = State(initialValue: .lucide)
        case .materialOutlined, .materialRounded, .materialSharp: _family = State(initialValue: .material)
        }
        _materialStyle = State(initialValue: [.materialRounded, .materialSharp].contains(library) ? library : .materialOutlined)
    }

    private var library: IconLibrary {
        switch family {
        case .sf: return .sf
        case .material: return materialStyle
        case .weui: return .weui
        case .lucide: return .lucide
        }
    }

    private static let columns = Array(repeating: GridItem(.fixed(40), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("Icon library"), selection: $family) {
                ForEach(Family.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 8) {
                TextField(L("Search Icons"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                if family == .material {
                    Picker(L("Style"), selection: $materialStyle) {
                        Text(L("Outlined")).tag(IconLibrary.materialOutlined)
                        Text(L("Rounded")).tag(IconLibrary.materialRounded)
                        Text(L("Sharp")).tag(IconLibrary.materialSharp)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if family == .sf {
                Text(L("SF Symbols may be used only in designs for Apple platforms."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            grid
        }
        .padding(12)
        .frame(width: 8 * 44 + 24, height: 440)
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss() }
        .task(id: "\(library.rawValue)\n\(query)") {
            let library = library, query = query
            let found = await Task.detached(priority: .userInitiated) { IconCatalog.shared.listing(query, library: library) }.value
            guard !Task.isCancelled else { return }
            results = found
            loaded = true
        }
    }

    @ViewBuilder private var grid: some View {
        if loaded && results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.tertiary)
                Text(L("No Icons")).font(.headline)
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(L("No icons match “%@”.", query)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 4) {
                    ForEach(results, id: \.self) { name in
                        IconCell(name: name, selected: name == current) {
                            choose(name)
                            dismiss()
                        }
                    }
                }
            }
            .id(library)
        }
    }
}

private struct IconCell: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let label = IconLibrary.parse(name)?.name ?? name
        Button(action: action) {
            Group {
                if let image = IconThumbnails.image(name) {
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                } else {
                    Image(systemName: "questionmark.square.dashed").resizable().scaledToFit().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)
            .frame(width: 40, height: 40)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(hovering ? 0.1 : 0)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label).accessibilityLabel(label)
    }
}

/// Template images of icons for the picker grid, made once per icon and tinted by SwiftUI with the label color.
@MainActor enum IconThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard var image = IconLayer.shape(name) else { return nil }
        if IconLibrary.parse(name)?.library == .sf, let sized = image.withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) {
            image = sized
        } else {
            image = image.copy() as! NSImage
        }
        image.isTemplate = true
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}
