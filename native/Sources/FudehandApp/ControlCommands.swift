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
            let node = try DesignJSON.node(from: DesignDocument.assigningIDs(Self.iconDefaults(object.value), existing: &existing))
            var icons: [String] = []
            DesignDocument(nodes: [node]).forEach { if let icon = $0.icon { icons.append(icon.name) } }
            try icons.forEach(requireIcon)
            try perform("Agent: Create Layers") { document in
                try document.insert(node, parent: parent, index: index)
                try Prototype.checkDestinations(of: node, in: document)
            }
            var ids: [String] = []
            DesignDocument(nodes: [node]).forEach { ids.append($0.id) }
            return ["id": node.id, "ids": ids, "node": DesignJSON.object(try requireNode(node.id), includeImageData: false)]
        case .updateNode(let id, let changes):
            // Only a name the update sets must exist: a layer opened from a file may name an icon this Mac lacks.
            if let name = (changes.value["icon"] as? [String: Any])?["name"] as? String { try requireIcon(name) }
            try perform("Agent: Update Layer") { document in
                try document.update(id) { try DesignJSON.apply(changes.value, to: &$0) }
                if changes.value["interaction"] != nil, let node = document.node(id) {
                    var shallow = node
                    shallow.children = []
                    try Prototype.checkDestinations(of: shallow, in: document)
                }
            }
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
        case .searchIcons(let query, let library, let limit):
            return ["icons": IconCatalog.shared.search(query, library: library, limit: limit)]
        case .importFont(let path):
            do { return ["families": try importFonts([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])] }
            catch let error as FontImportError { throw ControlCommandError(error.english) }
        case .showLaunchWindow:
            presentLaunch()
            return controlState()
        case .listRecents:
            return ["recents": recentsState()]
        case .openRecent(let path, let discard):
            let entry = try requireRecent(path)
            guard entry.available else {
                throw ControlCommandError("File not found: \(path) (deleted or moved); remove it from the list with app_remove_recent")
            }
            try openFile(URL(fileURLWithPath: entry.path)) { try requireDiscardable(discard); return true }
            return controlState()
        case .removeRecent(let path):
            let entry = try requireRecent(path)
            removeRecent(entry.path)
            return ["removed": [entry.path], "recents": recentsState()]
        case .clearRecents:
            let removed = recents.items.map(\.path)
            clearRecents()
            return ["removed": removed, "recents": recentsState()]
        case .listTemplates:
            return ["templates": templates.map { ["name": $0.name] }]
        case .newDocumentFromTemplate(let name, let discard):
            guard let template = templates.first(where: { $0.name == name }) else {
                throw ControlCommandError("Template not found: \(name); available: "
                    + (templates.isEmpty ? "none" : templates.map(\.name).joined(separator: ", ")))
            }
            try newDocument(fromTemplate: template) { try requireDiscardable(discard); return true }
            return controlState()
        case .exportHTML(let id, let directory):
            _ = try requireNode(id)
            let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            let result: DesignHTMLExport
            do { result = try exportHTML(id, to: url) } catch let error as HTMLExportError { throw ControlCommandError(error.english) }
            return ["id": id, "directory": url.path, "files": result.files.keys.sorted(), "assets": result.assets, "html": result.html]
        }
    }

    /// The entry for `path`, which may be spelled differently from the entry: entries are recorded with symlinks resolved.
    /// A file that no longer exists cannot be resolved itself, so its directory is resolved instead.
    private func requireRecent(_ path: String) throws -> RecentDocuments.Entry {
        let url = URL(fileURLWithPath: path)
        let spellings = [path, url.resolvingSymlinksInPath().path,
                         url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path]
        guard let entry = recentEntries.first(where: { spellings.contains($0.path) }) else {
            throw ControlCommandError("Not a recent file: \(path)")
        }
        return entry
    }

    private func recentsState() -> [[String: Any]] {
        let format = ISO8601DateFormatter()
        return recentEntries.map { entry in
            ["path": entry.path, "name": URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent,
             "openedAt": format.string(from: entry.openedAt), "available": entry.available]
        }
    }

    private func requireNode(_ id: String) throws -> DesignNode {
        guard let node = editor.document.node(id) else { throw ControlCommandError("Layer not found: \(id)") }
        return node
    }

    /// Agent edits may only use icons that exist; the error lists similar names to try instead.
    private func requireIcon(_ name: String) throws {
        guard !IconCatalog.shared.exists(name) else { return }
        let similar = IconCatalog.shared.suggestions(for: name)
        throw ControlCommandError("Unknown icon \(name)" + (similar.isEmpty ? "" : "; similar: \(similar.joined(separator: ", "))"))
    }

    /// A new icon layer without a size is 24 × 24, the common icon size, rather than the 100 × 100 other layers get.
    nonisolated static func iconDefaults(_ object: [String: Any]) -> [String: Any] {
        var object = object
        if object["type"] as? String == NodeType.icon.rawValue {
            for key in ["width", "height"] where object[key] == nil || object[key] is NSNull { object[key] = 24 }
        }
        if let children = object["children"] as? [Any] { object["children"] = children.map { ($0 as? [String: Any]).map(iconDefaults) ?? $0 } }
        return object
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
