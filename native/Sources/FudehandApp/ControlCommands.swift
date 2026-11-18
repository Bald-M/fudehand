import FudehandCore
import Foundation

/// Control-channel commands are dispatched to the store on the main thread; the result is a dictionary that can be encoded as JSON. Agent edits share the undo history with manual edits.
extension FudehandStore {
    func handleControl(_ command: ControlCommand) async throws -> Any {
        switch command {
        case .getState:
            return controlState()
        case .getDocument:
            return ["format": DesignDocument.format, "version": DesignDocument.formatVersion,
                    "nodes": editor.document.nodes.map { DesignJSON.object($0, includeImageData: false) }]
        case .getNode(let id):
            return DesignJSON.object(try requireNode(id), includeImageData: false)
        case .createNode(let parent, let index, let object):
            var existing = editor.document.allIDs()
            let node = try DesignJSON.node(from: DesignDocument.assigningIDs(object.value, existing: &existing))
            try perform("Agent: Create Layers") { try $0.insert(node, parent: parent, index: index) }
            var ids: [String] = []
            DesignDocument(nodes: [node]).forEach { ids.append($0.id) }
            return ["id": node.id, "ids": ids, "node": DesignJSON.object(try requireNode(node.id), includeImageData: false)]
        case .updateNode(let id, let changes):
            try perform("Agent: Update Layer") { try $0.update(id) { try DesignJSON.apply(changes.value, to: &$0) } }
            return DesignJSON.object(try requireNode(id), includeImageData: false)
        case .deleteNodes(let ids):
            try perform("Agent: Delete Layers") { try $0.delete(Set(ids)) }
            return ["deleted": ids]
        case .moveNode(let id, let parent, let index):
            try perform("Agent: Move Layer") { try $0.move(id, parent: parent, index: index) }
            return DesignJSON.object(try requireNode(id), includeImageData: false)
        case .select(let ids):
            for id in ids { _ = try requireNode(id) }
            setSelection(Set(ids))
            return controlState()
        case .undo:
            guard canUndo else { throw ControlCommandError("Nothing to undo") }
            undo()
            return controlState()
        case .redo:
            guard canRedo else { throw ControlCommandError("Nothing to redo") }
            redo()
            return controlState()
        case .newDocument(let discard):
            try requireDiscardable(discard)
            replace(DesignDocument(), url: nil)
            return controlState()
        case .openDocument(let path, let discard):
            try requireDiscardable(discard)
            try open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            return controlState()
        case .saveDocument(let path):
            guard let url = path.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) ?? fileURL else {
                throw ControlCommandError("The document has never been saved; provide path")
            }
            do { try write(to: url) } catch { throw ControlCommandError("Could not save: \(error.localizedDescription)") }
            return controlState()
        case .focusNode(let id):
            _ = try requireNode(id)
            focus(id)
            return controlState()
        case .fitAll:
            fitAll()
            return controlState()
        case .zoom(let scale):
            zoom(scale)
            return controlState()
        case .nodeSnapshot(let id, let scale):
            let node = try requireNode(id)
            let png = try DesignRenderer.snapshotPNG(node, scale: scale)
            return ["id": id, "mimeType": "image/png", "data": png.base64EncodedString(), "width": node.width, "height": node.height]
        case .listFonts:
            return ["fonts": fontFamilies.map { ["family": $0.name, "source": $0.imported ? "imported" : "system"] }]
        case .importFont(let path):
            do { return ["families": try importFonts([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])] }
            catch let error as FontImportError { throw ControlCommandError(error.english) }
        }
    }

    private func requireNode(_ id: String) throws -> DesignNode {
        guard let node = editor.document.node(id) else { throw ControlCommandError("Layer not found: \(id)") }
        return node
    }

    private func requireDiscardable(_ discard: Bool) throws {
        if isDirty, !discard { throw ControlCommandError("The current document has unsaved changes; save it first, or pass discard: true to discard them") }
    }

    func controlState() -> [String: Any] {
        let current = zoomIndicator.viewport
        return [
            "file": fileURL?.path ?? NSNull(),
            "name": title,
            "dirty": isDirty,
            "selection": selection.sorted(),
            "viewport": ["x": current.x, "y": current.y, "scale": current.scale],
            "canUndo": canUndo,
            "canRedo": canRedo,
            "nodeCount": editor.document.nodeCount,
            "nodes": editor.document.nodes.map { node -> [String: Any] in
                ["id": node.id, "type": node.type.rawValue, "name": node.name, "x": node.x, "y": node.y,
                 "width": node.width, "height": node.height, "children": node.children.count]
            },
        ]
    }
}
