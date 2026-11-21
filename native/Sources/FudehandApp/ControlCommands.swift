import FudehandCore
import Foundation

/// Control-channel commands are dispatched to the store on the main thread; the result is a dictionary that can be encoded as JSON. Agent edits share the undo history with manual edits.
extension FudehandStore {
    /// `caller` is the chat panel conversation whose Agent sent the command; nil for any other caller.
    func handleControl(_ command: ControlCommand, caller: UUID? = nil) async throws -> Any {
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
        case .copyNodes(let ids, let cut):
            let copied = try copyLayers(Set(try colorLayers(ids)), cut: cut, step: "Agent: Cut Layers")
            return ["copied": copied, "cut": cut]
        case .paste:
            return try pastedResult(try pasteLayers(step: "Agent: Paste Layers"))
        case .duplicateNodes(let ids):
            return try pastedResult(try duplicateLayers(Set(try colorLayers(ids)), step: "Agent: Duplicate Layers"))
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
        case .focusNodes(let ids):
            for id in ids { _ = try requireNode(id) }
            focus(ids)
            return controlState()
        case .setView(let change):
            for id in change.expand + change.collapse where try requireNode(id).children.isEmpty {
                throw ControlCommandError("Layer has no child layers to expand or collapse: \(id)")
            }
            let previous = viewState()
            if let tool = change.tool { self.tool = tool }
            if let inspector = change.inspector { showingInspector = inspector }
            if let tab = change.inspectorTab { inspectorTab = tab }
            for id in change.expand { setCollapsed(id, false) }
            for id in change.collapse { setCollapsed(id, true) }
            return ["previous": previous, "view": viewState()]
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
        case .saveVersionSnapshot(let frame, let note):
            let node = try saveVersionSnapshot(of: frame, note: note, step: "Agent: Save Version Snapshot")
            return versionSnapshotEntry(try requireNode(node.id))
        case .listVersionSnapshots(let frame):
            return ["snapshots": editor.document.versionSnapshots(of: frame).map(versionSnapshotEntry)]
        case .listShaders:
            return ShaderCatalog.object
        case .listFonts:
            return ["fonts": fontFamilies.map { ["family": $0.name, "source": $0.imported ? "imported" : "system"] }]
        case .searchIcons(let query, let library, let limit):
            return ["icons": IconCatalog.shared.search(query, library: library, limit: limit)]
        case .listColors(let ids):
            return selectionColorsResult(try colorLayers(ids))
        case .replaceColor(let from, let to, let ids):
            let layers = try colorLayers(ids)
            let uses = SelectionColors.uses(of: from, under: Set(layers), in: editor.document)
            guard !uses.isEmpty else { throw ControlCommandError("None of these layers or their child layers uses \(from.hex)") }
            let replaced = try setColor(to, at: uses, "Agent: Replace Color")
            return selectionColorsResult(layers).merging(["replaced": replaced]) { $1 }
        case .getInterface, .updateInterface, .getModels, .updateModelProvider, .listModels, .setAPIKey, .deleteAPIKey, .getConnectors, .setConnector:
            return try await handleSettings(command)
        case .importFont(let path):
            do { return ["families": try importFonts([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])] }
            catch let error as FontImportError { throw ControlCommandError(error.english) }
        case .playPrototype(let frame):
            try playPrototype(from: frame)
            return prototypePlayback()
        case .getPrototypePlayback:
            return prototypePlayback()
        case .closePrototype:
            guard prototypeWindowOpen else { throw ControlCommandError("The prototype window is not open") }
            closePrototype()
            return prototypePlayback()
        case .showLaunchWindow:
            presentLaunch()
            return controlState()
        case .closeEditorWindow(let discard):
            try closeEditor { try requireDiscardable(discard); return true }
            dismissEditor()
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
            return ["templates": templates.map { ["name": $0.name, "title": $0.title] }]
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
        case .listConversations, .getConversation, .openConversation, .newConversation, .closeConversation, .deleteConversation,
             .clearConversation, .sendMessage, .setMode, .runPlan, .stopReply, .regenerateReply, .editLastMessage, .answerQuestion, .compactConversation:
            return try handleChatControl(command, caller: caller)
        case .listAnnotations(let node):
            if let node { _ = try requireNode(node) }
            let annotations = node.map(editor.document.annotations(on:)) ?? editor.document.annotations
            return ["annotations": annotations.map(\.object)]
        case .addAnnotation(let node, let x, let y, let text, let replyTo):
            if let replyTo { return try replyToAnnotation(replyTo, text: text, by: .agent).object }
            return try addAnnotation(on: node!, x: x, y: y, text: text, by: .agent).object
        case .updateAnnotation(let id, let text):
            return try updateAnnotation(id, text: text, by: .agent).object
        case .deleteAnnotation(let id):
            try deleteAnnotation(id, by: .agent)
            return ["deleted": id]
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

    /// Whether the prototype window is open and the top-level frame it shows (null when closed, or when that frame was deleted).
    func prototypePlayback() -> [String: Any] {
        let frame = prototypeWindowOpen ? prototypeFrame.flatMap { Prototype.frame($0, in: editor.document) } : nil
        return ["open": prototypeWindowOpen, "frame": frame?.id ?? NSNull(), "name": frame?.name ?? NSNull()]
    }

    /// A version snapshot as the Agent reads it: the record, where the snapshot and its frame are on the canvas (absolute
    /// coordinates; `frameBounds` and `frameName` are null once the frame is deleted), and its opacity, for comparing the two.
    private func versionSnapshotEntry(_ node: DesignNode) -> [String: Any] {
        let document = editor.document
        func bounds(_ rect: Rect?) -> Any {
            rect.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] as [String: Any] } ?? NSNull()
        }
        let snapshot = node.versionSnapshot!
        return ["id": node.id, "name": node.name, "frame": snapshot.frame, "frameName": document.node(snapshot.frame)?.name ?? NSNull(),
                "createdAt": snapshot.timestamp, "note": snapshot.note, "opacity": node.opacity,
                "bounds": bounds(document.worldRect(node.id)), "frameBounds": bounds(document.worldRect(snapshot.frame))]
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

    /// The new layers made by Paste or Duplicate, as `design_create_node` returns a layer.
    private func pastedResult(_ ids: [String]) throws -> [String: Any] {
        ["ids": ids, "nodes": try ids.map { DesignJSON.object(try requireNode($0), includeImageData: false) }]
    }

    /// The layers a command reads or changes (selection colors, copy, duplicate): those named, or else the selection.
    private func colorLayers(_ ids: [String]?) throws -> [String] {
        guard let ids else {
            guard !selection.isEmpty else { throw ControlCommandError("Nothing is selected; select layers or pass ids") }
            return selection.sorted()
        }
        for id in ids { _ = try requireNode(id) }
        return ids
    }

    private func selectionColorsResult(_ ids: [String]) -> [String: Any] {
        ["ids": ids, "colors": SelectionColors.collect(Set(ids), in: editor.document).map { ["color": $0.color.hex, "count": $0.count] }]
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
            "view": viewState(),
            "canUndo": canUndo,
            "canRedo": canRedo,
            "nodeCount": editor.document.nodeCount,
            "nodes": editor.document.nodes.map { node -> [String: Any] in
                ["id": node.id, "type": node.type.rawValue, "name": node.name, "x": node.x, "y": node.y,
                 "width": node.width, "height": node.height, "children": node.children.count]
            },
        ]
    }

    /// The editor view outside the document: the canvas tool, the inspector, and the layers the layers panel collapses.
    func viewState() -> [String: Any] {
        ["tool": tool.rawValue, "inspector": showingInspector, "inspectorTab": inspectorTab.rawValue,
         "collapsed": collapsedLayers.filter { editor.document.node($0) != nil }.sorted()]
    }
}
