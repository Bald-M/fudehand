import AtlasCore
import Foundation

/// 控制通道命令在主线程上分发到 store；结果是可编码为 JSON 的字典。
extension AtlasStore {
    func handleControl(_ command: ControlCommand) async throws -> Any {
        switch command {
        case .getState:
            return controlState()
        case .selectProject(let id):
            guard let next = catalog?.projects.first(where: { $0.id == id }) else { throw ControlCommandError("找不到作品：\(id)") }
            guard next.enabled else { throw ControlCommandError("作品已停用：\(id)") }
            select(next)
            return controlState()
        case .focusFrame(let id):
            try requireFrame(id)
            focusFrame(id)
            return controlState()
        case .fitAll:
            fitAll()
            return controlState()
        case .zoom(let scale):
            zoom(scale)
            return controlState()
        case .reset:
            reset()
            return controlState()
        case .restartPreview:
            guard root != nil else { throw ControlCommandError("尚未打开项目目录") }
            guard !opening else { throw ControlCommandError("正在打开项目，请稍后再试") }
            restart()
            return ["restarting": true]
        case .frameSnapshot(let id):
            let frame = try requireFrame(id)
            guard let view = canvas?.frames[id], view.isReady else { throw ControlCommandError("画框尚未加载：\(id)") }
            let png = try await view.snapshotPNG()
            return ["frame": id, "mimeType": "image/png", "data": png.base64EncodedString(),
                    "width": frame.width, "height": frame.height]
        }
    }

    @discardableResult
    private func requireFrame(_ id: String) throws -> Frame {
        guard let frame = project?.frames.first(where: { $0.id == id }) else { throw ControlCommandError("当前作品没有画框：\(id)") }
        return frame
    }

    private func controlState() -> [String: Any] {
        let phase: String
        var failure: Any = NSNull()
        switch session.phase {
        case .stopped: phase = "stopped"
        case .starting: phase = "starting"
        case .ready: phase = "ready"
        case .failed(let message): phase = "failed"; failure = message
        }
        // 视口取画布最近一次请求或稳定后的值。
        let current = zoomIndicator.viewport
        return [
            "project": project?.id ?? NSNull(),
            "projects": (catalog?.projects ?? []).map { ["id": $0.id, "title": $0.title, "enabled": $0.enabled] },
            "selection": selection.sorted(),
            "viewport": ["x": current.x, "y": current.y, "scale": current.scale],
            "frames": (project?.frames ?? []).map { frame -> [String: Any] in
                let point = positions[frame.id] ?? Point(x: frame.x, y: frame.y)
                return ["id": frame.id, "title": frame.title, "platform": frame.platform,
                        "x": point.x, "y": point.y, "width": frame.width, "height": frame.height]
            },
            "phase": phase,
            "error": failure,
        ]
    }
}
