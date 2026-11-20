import AppKit
import FudehandCore
import SwiftUI

/// Annotation edits. The canvas popover and the control channel both call these, so a person's and an Agent's edits are the same
/// undo steps; an Agent's are named `Agent: …` (ADR 0010).
extension FudehandStore {
    private func stepName(_ action: String, _ author: AnnotationAuthor) -> String { author == .agent ? "Agent: \(action)" : action }

    /// Pins a new annotation to a layer; `x` and `y` are relative to the layer, and nil puts it at the layer's center.
    @discardableResult
    func addAnnotation(on node: String, x: Double?, y: Double?, text: String, by author: AnnotationAuthor) throws -> DesignAnnotation {
        guard let layer = editor.document.node(node) else { throw DesignError("Layer not found: \(node)") }
        var added: DesignAnnotation?
        try perform(stepName("Add Annotation", author)) {
            added = try $0.addAnnotation(on: node, x: x ?? layer.width / 2, y: y ?? layer.height / 2, text: text, author: author)
        }
        return added!
    }

    /// Adds a reply to the thread holding `id` (an annotation or one of its replies) and returns the whole annotation.
    @discardableResult
    func replyToAnnotation(_ id: String, text: String, by author: AnnotationAuthor) throws -> DesignAnnotation {
        try perform(stepName("Reply to Annotation", author)) { try $0.replyToAnnotation(id, text: text, author: author) }
        return editor.document.annotation(containing: id)!
    }

    /// Replaces the text of an annotation or a reply and returns the whole annotation.
    @discardableResult
    func updateAnnotation(_ id: String, text: String, by author: AnnotationAuthor) throws -> DesignAnnotation {
        try perform(stepName("Edit Annotation", author)) { try $0.updateAnnotation(id, text: text) }
        return editor.document.annotation(containing: id)!
    }

    /// Deletes an annotation with its thread, or one reply.
    func deleteAnnotation(_ id: String, by author: AnnotationAuthor) throws {
        try perform(stepName("Delete Annotation", author)) { try $0.deleteAnnotation(id) }
    }

    /// Adds the annotation being written on the canvas and shows its thread in its place.
    func submitAnnotationDraft(_ text: String) throws {
        guard case .draft(let node, let x, let y) = annotation else { return }
        let added = try addAnnotation(on: node, x: x, y: y, text: text, by: .person)
        expandAnnotation(.thread(added.id))
    }

    /// Expands an annotation's thread next to its marker, or collapses it (nil).
    func expandAnnotation(_ target: AnnotationTarget?) {
        if annotation != target { annotation = target }
        canvas?.showAnnotation(target) {
            let controller = NSHostingController(rootView: AnnotationThread(store: self).environment(\.locale, language.locale))
            controller.sizingOptions = .preferredContentSize
            return controller
        }
    }

    /// After a document change: collapses the thread whose annotation or layer is gone (deleted, undone, or another file opened).
    func syncAnnotation() {
        switch annotation {
        case .thread(let id) where editor.document.annotations.contains(where: { $0.id == id }): canvas?.refreshOverlay()
        case .draft(let node, _, _) where index.contains(node): canvas?.refreshOverlay()
        case nil: break
        default: expandAnnotation(nil)
        }
    }

    func canvasToggleAnnotation(_ id: String) { expandAnnotation(annotation == .thread(id) ? nil : .thread(id)) }

    func canvasAnnotate(_ node: String, at point: Point) {
        guard let rect = index.worldRect(node) else { return }
        tool = .move
        expandAnnotation(.draft(node: node, x: point.x - rect.x, y: point.y - rect.y))
    }

    func canvasCollapseAnnotation() { expandAnnotation(nil) }
}

/// The expanded annotation: its thread with replies, or the field for writing a new one.
struct AnnotationThread: View {
    @ObservedObject var store: FudehandStore
    @State private var reply = ""
    @State private var editing: String?
    @State private var editText = ""
    @FocusState private var composing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch store.annotation {
            case .draft(let node, _, _):
                header(node)
                composer(L("Add an annotation"), action: L("Add")) { try store.submitAnnotationDraft($0) }
            case .thread(let id):
                if let annotation = store.document.annotations.first(where: { $0.id == id }) {
                    header(annotation.node)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            entry(id: annotation.id, author: annotation.author, text: annotation.text, root: true)
                            ForEach(annotation.replies) { entry(id: $0.id, author: $0.author, text: $0.text, root: false) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    composer(L("Reply"), action: L("Reply")) { try store.replyToAnnotation(id, text: $0, by: .person) }
                }
            case nil:
                EmptyView()
            }
        }
        .padding(16)
        .frame(width: 300)
        .onExitCommand { store.expandAnnotation(nil) }
        .onAppear { if case .draft = store.annotation { composing = true } }
    }

    private func header(_ node: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Annotation")).font(.headline)
            Text(store.document.node(node)?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func composer(_ prompt: String, action: String, submit: @escaping (String) throws -> Void) -> some View {
        let blank = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let send = {
            guard !blank else { return }
            do { try submit(reply); reply = "" } catch { store.alert = error.localizedDescription }
        }
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(prompt, text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($composing)
                .onSubmit(send)
            Button(action, action: send).disabled(blank)
        }
    }

    private func entry(id: String, author: AnnotationAuthor, text: String, root: Bool) -> some View {
        let deleteLabel = root ? L("Delete Annotation") : L("Delete Reply")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(author == .agent ? L("Agent") : L("You")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: { editing = id; editText = text }) { Image(systemName: "pencil").iconHitTarget() }
                    .buttonStyle(.borderless).help(L("Edit")).accessibilityLabel(L("Edit"))
                Button(action: { perform { try store.deleteAnnotation(id, by: .person) } }) { Image(systemName: "trash").iconHitTarget() }
                    .buttonStyle(.borderless).help(deleteLabel).accessibilityLabel(deleteLabel)
            }
            if editing == id {
                TextField("", text: $editText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...8)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button(L("Cancel")) { editing = nil }
                    Button(L("Save"), action: save)
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard let id = editing else { return }
        perform { try store.updateAnnotation(id, text: editText, by: .person) }
        editing = nil
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() } catch { store.alert = error.localizedDescription }
    }
}
