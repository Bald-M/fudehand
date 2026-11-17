import Foundation

/// 画布点击选中哪个图层（Figma 式规则），不依赖 AppKit。
public enum DesignHitTest {
    /// 画布坐标点下最上层的可见、未锁定图层，从顶层到最深层的 id 路径。锁定或隐藏的图层及其子图层被跳过；
    /// 裁剪内容的画框外的子图层不可点中。
    public static func path(at point: Point, in document: DesignDocument) -> [String] {
        func search(_ nodes: [DesignNode], origin: Point) -> [String]? {
            for node in nodes.reversed() where node.visible && !node.locked {
                let rect = Rect(x: origin.x + node.x, y: origin.y + node.y, width: node.width, height: node.height)
                let inside = point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
                let clips = node.type == .frame && node.clipsContent
                if !clips || inside, let deeper = search(node.children, origin: Point(x: rect.x, y: rect.y)) {
                    return [node.id] + deeper
                }
                // 分组没有自己的内容，只能经子图层点中。
                if inside, node.type != .group { return [node.id] }
            }
            return nil
        }
        return search(document.nodes, origin: Point(x: 0, y: 0)) ?? []
    }

    /// 按当前选择决定点中路径上的哪一层：顶层画框内直接选中其子图层；已选图层的兄弟可直接点中；
    /// `deep`（⌘ + 点击）选中最深一层。
    public static func selectable(path: [String], selection: Set<String>, document: DesignDocument, deep: Bool) -> String? {
        guard !path.isEmpty else { return nil }
        if deep { return path.last }
        var depth = 0
        if path.count > 1, document.node(path[0])?.type == .frame { depth = 1 }
        for id in selection {
            let ancestry = document.ancestry(of: id)
            let level = ancestry.count - 1
            if level > depth, path.count > level, Array(path.prefix(level)) == Array(ancestry.prefix(level)) { depth = level }
        }
        return path[min(depth, path.count - 1)]
    }

    /// 双击已选图层：选中指针下它的下一层子图层；没有时返回 nil。
    public static func enter(_ id: String, at point: Point, in document: DesignDocument) -> String? {
        let hit = path(at: point, in: document)
        guard let index = hit.firstIndex(of: id), index + 1 < hit.count else { return nil }
        return hit[index + 1]
    }
}
