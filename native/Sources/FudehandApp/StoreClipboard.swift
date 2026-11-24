import AppKit
import FudehandCore

/// Copy, Cut, Paste, and Duplicate of layers (see "Copy and Paste" in `docs/macos.md`). The Edit menu, the layers panel, and
/// the control channel all call these.
extension FudehandStore {
    static let layersType = NSPasteboard.PasteboardType(LayerClipboard.pasteboardType)

    /// The part of the canvas in view, in canvas coordinates.
    var visibleRect: Rect {
        let topLeft = CanvasGeometry.screenToWorld(Point(x: 0, y: 0), viewport: viewport)
        let bottomRight = CanvasGeometry.screenToWorld(Point(x: canvasSize.width, y: canvasSize.height), viewport: viewport)
        return Rect.spanning(topLeft, bottomRight)
    }

    var canPasteLayers: Bool { pasteboard.availableType(from: [Self.layersType]) != nil }

    /// Puts the layers on the pasteboard; `cut` also deletes them, as one undo step. Returns the ids of the outermost copied
    /// layers (a layer copied with its ancestor goes with the ancestor).
    @discardableResult
    func copyLayers(_ ids: Set<String>, cut: Bool, step: String = "Cut Layers") throws -> [String] {
        let clip = try LayerClipboard(copying: ids, from: editor.document)
        let data = try clip.data()
        if cut {
            try perform(step) { try $0.delete(Set(clip.sources), detachingInstances: false) }
            setSelection([])
        }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.layersType)
        // After a cut the first paste goes back in place; after a copy it is moved one step.
        clipboardPastes = (changeCount: pasteboard.changeCount, step: cut ? 0 : 1, pasted: [])
        return clip.sources
    }

    /// Pastes the layers on the pasteboard as one undo step, selects the copies, and returns their ids.
    @discardableResult
    func pasteLayers(step: String = "Paste Layers") throws -> [String] {
        guard let data = pasteboard.data(forType: Self.layersType) else { throw DesignError("The clipboard holds no layers") }
        let clip = try LayerClipboard(data: data)
        var state = clipboardPastes.changeCount == pasteboard.changeCount ? clipboardPastes
            : (changeCount: pasteboard.changeCount, step: 1, pasted: Set<String>())
        let frame = clip.target(selection: selection, in: editor.document, excluding: Set(clip.sources).union(state.pasted))
        var ids: [String] = []
        try perform(step) { ids = try clip.paste(into: &$0, frame: frame, visible: visibleRect, step: state.step, related: state.pasted) }
        state.step += 1
        state.pasted.formUnion(ids)
        clipboardPastes = state
        setSelection(Set(ids))
        return ids
    }

    /// Copies each layer just above itself in its own parent, one step down and right, without touching the pasteboard; one undo
    /// step. Selects the copies and returns their ids.
    @discardableResult
    func duplicateLayers(_ ids: Set<String>, step: String = "Duplicate Layers") throws -> [String] {
        let clip = try LayerClipboard(copying: ids, from: editor.document)
        var copies: [String] = []
        try perform(step) { copies = try clip.duplicate(in: &$0) }
        setSelection(Set(copies))
        return copies
    }

    // The UI entry points show an error in an alert.

    /// Does nothing when the pasteboard holds no layers, as the disabled menu item would.
    func paste() {
        guard canPasteLayers else { return }
        do { try pasteLayers() } catch { alert = error.localizedDescription }
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        do { try duplicateLayers(selection) } catch { alert = error.localizedDescription }
    }
}

extension FudehandStore {
    func canvasCopy(_ ids: Set<String>, cut: Bool) {
        guard !ids.isEmpty, !cut || !hasLayersInsideInstance(ids) else { return }
        do { try copyLayers(ids, cut: cut) } catch { alert = error.localizedDescription }
    }

    func canvasPaste() { paste() }

    var canvasCanPaste: Bool { canPasteLayers }

    func canvasCanRestructure(_ ids: Set<String>) -> Bool { !hasLayersInsideInstance(ids) }
}
