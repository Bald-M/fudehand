import AtlasCore
import Foundation

/// 控制通道命令在主线程上分发到 store；结果是可编码为 JSON 的字典。Agent 的修改与人工修改共用撤销历史。
extension AtlasStore {
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
            guard canUndo else { throw ControlCommandError("没有可撤销的修改") }
            undo()
            return controlState()
        case .redo:
            guard canRedo else { throw ControlCommandError("没有可重做的修改") }
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
                throw ControlCommandError("文档还没有保存过，请提供 path")
            }
            do { try write(to: url) } catch { throw ControlCommandError("无法保存：\(error.localizedDescription)") }
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
        }
    }

    private func requireNode(_ id: String) throws -> DesignNode {
        guard let node = editor.document.node(id) else { throw ControlCommandError("找不到图层：\(id)") }
        return node
    }

    private func requireDiscardable(_ discard: Bool) throws {
        if isDirty, !discard { throw ControlCommandError("当前文档有未保存的修改；先保存，或传 discard: true 放弃修改") }
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
