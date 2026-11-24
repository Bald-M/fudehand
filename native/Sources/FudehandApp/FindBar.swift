import FudehandCore
import SwiftUI

/// The find bar's state. Kept out of the store's published state so typing a query redraws only the find bar and the Edit
/// menu's find items (#257).
final class FindModel: ObservableObject {
    @Published fileprivate(set) var isOpen = false
    @Published fileprivate(set) var query = ""
    @Published fileprivate(set) var matches: [DesignFind.Match] = []
    /// The index in `matches` of the match last stepped to; nil before the first step.
    @Published fileprivate(set) var current: Int?
    /// Bumped each time Find is chosen, so the search field takes focus again when the bar is already open.
    @Published fileprivate(set) var focusToken = 0
}

extension FudehandStore {
    /// Edit › Find (⌘F): opens the find bar and focuses its search field.
    func openFind() {
        find.isOpen = true
        find.focusToken += 1
    }

    /// Closes the find bar and clears its query; the selection stays on the last match.
    func closeFind() {
        find.isOpen = false
        find.query = ""
        find.matches = []
        find.current = nil
    }

    func setFindQuery(_ query: String) {
        guard query != find.query else { return }
        find.query = query
        find.matches = findLayers(query)
        find.current = nil
    }

    /// Find Next (⌘G, Return in the search field): selects and shows the next match, wrapping after the last.
    func findNext() { step(by: 1) }

    /// Find Previous (⇧⌘G, Shift-Return in the search field): selects and shows the previous match, wrapping before the first.
    func findPrevious() { step(by: -1) }

    private func step(by offset: Int) {
        guard find.isOpen, !find.matches.isEmpty else { return }
        let count = find.matches.count
        let next = find.current.map { ($0 + offset + count) % count } ?? (offset > 0 ? 0 : count - 1)
        find.current = next
        let id = find.matches[next].id
        setSelection([id])
        focus(id)
    }

    /// Recomputes the matches after the document changes, keeping the current match when it is still at the same place.
    func refreshFind() {
        guard find.isOpen, !find.query.isEmpty else { return }
        let previous = find.current.map { find.matches[$0].id }
        find.matches = findLayers(find.query)
        if let current = find.current, find.matches.indices.contains(current), find.matches[current].id == previous { return }
        find.current = find.matches.isEmpty ? nil : find.current.map { min($0, find.matches.count - 1) }
    }
}

/// The find bar over the top-right corner of the canvas: a search field, the match count, and previous / next / close buttons.
struct FindBar: View {
    let store: FudehandStore
    @ObservedObject var find: FindModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L("Find"), text: Binding(get: { find.query }, set: { store.setFindQuery($0) }))
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($fieldFocused)
                .onSubmit { store.findNext() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    store.findPrevious()
                    return .handled
                }
                .onExitCommand { store.closeFind() }
            Text(status).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Button { store.findPrevious() } label: { Image(systemName: "chevron.up").iconHitTarget() }
                .help(L("Previous Match (⇧⌘G)")).accessibilityLabel(L("Previous Match"))
                .disabled(find.matches.isEmpty)
            Button { store.findNext() } label: { Image(systemName: "chevron.down").iconHitTarget() }
                .help(L("Next Match (⌘G)")).accessibilityLabel(L("Next Match"))
                .disabled(find.matches.isEmpty)
            Button { store.closeFind() } label: { Image(systemName: "xmark").iconHitTarget() }
                .help(L("Close Find (Esc)")).accessibilityLabel(L("Close Find"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .onAppear { fieldFocused = true }
        .onChange(of: find.focusToken) { fieldFocused = true }
    }

    private var status: String {
        if find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if find.matches.isEmpty { return L("No Results") }
        if let current = find.current { return "\(current + 1) / \(find.matches.count)" }
        return L("%d Results", find.matches.count)
    }
}

/// Edit › Find Next and Find Previous, available while the find bar is open. They observe the find bar themselves, as
/// Duplicate observes the selection.
struct FindStepMenuItems: View {
    let store: FudehandStore
    @ObservedObject var find: FindModel

    var body: some View {
        Button(L("Find Next")) { store.findNext() }
            .keyboardShortcut("g")
            .disabled(!find.isOpen || find.matches.isEmpty)
        Button(L("Find Previous")) { store.findPrevious() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!find.isOpen || find.matches.isEmpty)
    }
}
