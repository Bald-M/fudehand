import Foundation

/// 测量文字：`maxWidth` 为 nil 时返回单行自然宽度，否则按该宽度折行。App 用 CoreText 实现，测试用固定规则。
public typealias TextMeasure = (DesignText, _ maxWidth: Double?) -> Size

/// 自动布局、文字自适应和分组收缩。结果直接写回节点的 x/y/width/height，渲染只读这些值。
public enum DesignLayout {
    public static func apply(to nodes: inout [DesignNode], measure: TextMeasure) {
        // 宽度在自顶向下阶段才确定，会影响折行文字的高度和 hug 父节点，所以运行两遍。
        for _ in 0..<2 {
            for index in nodes.indices {
                measureUp(&nodes[index], inAutoLayout: false, measure: measure)
                layoutDown(&nodes[index])
            }
        }
    }

    /// 自底向上：文字尺寸、分组并集、hug 画框尺寸。
    static func measureUp(_ node: inout DesignNode, inAutoLayout: Bool, measure: TextMeasure) {
        let childrenInLayout = node.layout != nil
        for index in node.children.indices {
            measureUp(&node.children[index], inAutoLayout: childrenInLayout, measure: measure)
        }
        switch node.type {
        case .text:
            guard let text = node.text else { return }
            let fillsWidth = inAutoLayout && node.sizing.horizontal == .fill
            let hugWidth = !fillsWidth && (text.autoResize == .widthAndHeight || node.sizing.horizontal == .hug)
            let hugHeight = text.autoResize != .none || node.sizing.vertical == .hug
            if hugWidth { node.width = measure(text, nil).width }
            if hugHeight { node.height = measure(text, node.width).height }
        case .group:
            guard let union = Rect.union(node.children.map(\.frame)) else { return }
            for index in node.children.indices {
                node.children[index].x -= union.x
                node.children[index].y -= union.y
            }
            node.x += union.x
            node.y += union.y
            node.width = union.width
            node.height = union.height
        case .frame:
            guard let layout = node.layout else { return }
            let visible = node.children.filter(\.visible)
            let horizontal = layout.direction == .horizontal
            let primary = visible.map { horizontal ? $0.width : $0.height }
            let cross = visible.map { horizontal ? $0.height : $0.width }
            let gaps = layout.spacing * Double(max(visible.count - 1, 0))
            let padding = layout.padding
            if node.sizing.horizontal == .hug {
                node.width = padding.left + padding.right + (horizontal ? primary.reduce(0, +) + gaps : cross.max() ?? 0)
            }
            if node.sizing.vertical == .hug {
                node.height = padding.top + padding.bottom + (horizontal ? cross.max() ?? 0 : primary.reduce(0, +) + gaps)
            }
        default:
            break
        }
    }

    /// 自顶向下：自动布局画框分配 fill 尺寸、拉伸交叉轴、摆放子项，再递归。
    static func layoutDown(_ node: inout DesignNode) {
        if let layout = node.layout {
            let horizontal = layout.direction == .horizontal
            let padding = layout.padding
            let innerPrimary = horizontal ? node.width - padding.left - padding.right : node.height - padding.top - padding.bottom
            let innerCross = horizontal ? node.height - padding.top - padding.bottom : node.width - padding.left - padding.right
            let indices = node.children.indices.filter { node.children[$0].visible }
            func fillsPrimary(_ child: DesignNode) -> Bool { (horizontal ? child.sizing.horizontal : child.sizing.vertical) == .fill }
            func fillsCross(_ child: DesignNode) -> Bool {
                layout.crossAlign == .stretch || (horizontal ? child.sizing.vertical : child.sizing.horizontal) == .fill
            }
            let gaps = layout.spacing * Double(max(indices.count - 1, 0))
            let fixedTotal = indices.filter { !fillsPrimary(node.children[$0]) }
                .reduce(0.0) { $0 + (horizontal ? node.children[$1].width : node.children[$1].height) }
            let fillCount = indices.filter { fillsPrimary(node.children[$0]) }.count
            let fillSize = fillCount == 0 ? 0 : max(0, (innerPrimary - fixedTotal - gaps) / Double(fillCount))
            for index in indices {
                let child = node.children[index]
                if fillsPrimary(child) {
                    if horizontal { node.children[index].width = fillSize } else { node.children[index].height = fillSize }
                }
                if fillsCross(child) {
                    if horizontal { node.children[index].height = max(0, innerCross) } else { node.children[index].width = max(0, innerCross) }
                }
            }
            let sizes = indices.map { horizontal ? node.children[$0].width : node.children[$0].height }
            let total = sizes.reduce(0, +) + gaps
            var cursor: Double
            var spacing = layout.spacing
            switch layout.align {
            case .start: cursor = 0
            case .center: cursor = (innerPrimary - total) / 2
            case .end: cursor = innerPrimary - total
            case .spaceBetween:
                cursor = 0
                if indices.count > 1 { spacing = (innerPrimary - sizes.reduce(0, +)) / Double(indices.count - 1) }
            }
            for (offset, index) in indices.enumerated() {
                let crossSize = horizontal ? node.children[index].height : node.children[index].width
                let crossOffset: Double
                switch layout.crossAlign {
                case .start, .stretch: crossOffset = 0
                case .center: crossOffset = (innerCross - crossSize) / 2
                case .end: crossOffset = innerCross - crossSize
                }
                if horizontal {
                    node.children[index].x = padding.left + cursor
                    node.children[index].y = padding.top + crossOffset
                } else {
                    node.children[index].x = padding.left + crossOffset
                    node.children[index].y = padding.top + cursor
                }
                cursor += sizes[offset] + spacing
            }
        }
        for index in node.children.indices { layoutDown(&node.children[index]) }
    }
}
