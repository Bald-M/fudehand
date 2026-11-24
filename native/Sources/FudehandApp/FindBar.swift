import AppKit
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

    /// The count beside the search field: "n / m" once a match has been stepped to, "m Results" before that, "No Results" when
    /// nothing matches, and nothing for an empty query.
    var status: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if matches.isEmpty { return L("No Results") }
        if let current { return "\(current + 1) / \(matches.count)" }
        return matches.count == 1 ? L("1 Result") : L("%d Results", matches.count)
    }
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

    /// Recomputes the matches after the document changes. The current match follows its layer to its new place; when the layer no
    /// longer matches, there is no current match and the next step starts from the first.
    func refreshFind() {
        guard find.isOpen, !find.query.isEmpty else { return }
        let previous = find.current.map { find.matches[$0].id }
        find.matches = findLayers(find.query)
        find.current = previous.flatMap { id in find.matches.firstIndex { $0.id == id } }
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
                // The field editor turns Return and Shift-Return alike into a submit before `onKeyPress` sees them, so the
                // direction comes from the key event being handled.
                .onSubmit {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { store.findPrevious() } else { store.findNext() }
                }
                .onExitCommand { store.closeFind() }
            Text(find.status).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
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
