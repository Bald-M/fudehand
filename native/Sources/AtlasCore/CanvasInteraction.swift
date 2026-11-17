import Foundation

public enum CanvasTool: String, Equatable, CaseIterable, Sendable {
    case move, hand, frame, rectangle, ellipse, text

    /// 创建工具对应的图层类型。
    public var creates: NodeType? {
        switch self {
        case .frame: return .frame
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .move, .hand: return nil
        }
    }
}

/// 选框上的八个缩放把手。
public enum ResizeHandle: CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// 把手在矩形上的相对位置（0、0.5、1）。
    public var anchor: Point {
        Point(x: movesLeft ? 0 : movesRight ? 1 : 0.5, y: movesTop ? 0 : movesBottom ? 1 : 0.5)
    }
}

/// 指针下的目标；`node` 已由 App 按当前选择层级解析为可选中的图层。
public enum HitTarget: Equatable, Sendable {
    case empty
    case node(String)
    /// 顶层画框上方的名称标签。
    case label(String)
    case handle(String, ResizeHandle)
}

public enum PointerButton: Equatable { case primary, middle }

public struct PointerModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = PointerModifiers(rawValue: 1 << 0)
    public static let control = PointerModifiers(rawValue: 1 << 1)
}

public enum InteractionEffect: Equatable {
    case select(Set<String>)
    /// 开始一次连续修改，名称用作撤销步骤名。
    case beginGesture(String)
    /// 拖动中的图层左上角（画布绝对坐标）。
    case moveNodes([String: Point])
    /// 缩放中的图层矩形（画布绝对坐标）。
    case resize(String, Rect)
    case endGesture
    /// 屏幕坐标的框选或创建预览矩形；nil 隐藏。
    case marquee(Rect?)
    /// 画布坐标的吸附参考线。
    case guides([Guide])
    case pan(Viewport)
    /// 双击顶层画框标签：缩放聚焦。
    case focus(String)
    /// 双击已选图层：由 App 选中指针（画布坐标）下更深一层的图层。
    case enter(String, Point)
    /// 创建工具：在画布坐标矩形处新建图层。
    case create(NodeType, Rect)
}

public struct InteractionContext {
    public var viewport: Viewport
    /// 选中图层与顶层图层的画布绝对矩形。
    public var rects: [String: Rect]
    /// 框选的候选图层（顶层图层）。
    public var marqueeCandidates: Set<String>
    /// 拖动当前选择时可吸附的矩形（兄弟图层与父图层）。
    public var snapTargets: [Rect]
    /// 可以拖动移动的图层（不在自动布局中、未锁定）。
    public var movable: Set<String>
    public var selection: Set<String>
    public var tool: CanvasTool
    public var spaceHeld: Bool

    public init(viewport: Viewport, rects: [String: Rect], marqueeCandidates: Set<String>, snapTargets: [Rect] = [],
                movable: Set<String>, selection: Set<String>, tool: CanvasTool, spaceHeld: Bool) {
        self.viewport = viewport; self.rects = rects; self.marqueeCandidates = marqueeCandidates
        self.snapTargets = snapTargets; self.movable = movable; self.selection = selection
        self.tool = tool; self.spaceHeld = spaceHeld
    }
}

/// 把指针事件转换为画布效果的状态机；不依赖 AppKit。
public struct CanvasInteraction {
    public static let dragThreshold = 3.0
    public static let snapThreshold = 6.0
    /// 单击创建（未拖出尺寸）时的默认尺寸。
    public static let defaultSize = 100.0

    private struct Press {
        var origin: Point
        var dragIDs: Set<String>
        /// 在多选中按下（无 Shift）且未拖动时，松开后收缩为该图层。
        var collapseTo: String?
    }

    private struct Moving {
        var origin: Point
        var startRects: [String: Rect]
        var current: [String: Point]
    }

    private struct Resizing {
        var id: String
        var handle: ResizeHandle
        var origin: Point
        var start: Rect
        var started: Bool
    }

    private enum State {
        case idle
        case pressed(Press)
        case moving(Moving)
        case resizing(Resizing)
        case marquee(origin: Point, base: Set<String>)
        case creating(NodeType, origin: Point)
        case panning(origin: Point, viewport: Viewport)
    }

    private var state = State.idle

    public init() {}

    public var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    public mutating func pointerDown(at point: Point, hit: HitTarget, button: PointerButton, modifiers: PointerModifiers,
                                     clickCount: Int, context: InteractionContext) -> [InteractionEffect] {
        // 漏掉松开事件的上一个手势先结束。
        let leftover = isIdle ? [] : finish(at: point, context: context)
        return leftover + beginPress(at: point, hit: hit, button: button, modifiers: modifiers, clickCount: clickCount, context: context)
    }

    private mutating func beginPress(at point: Point, hit: HitTarget, button: PointerButton, modifiers: PointerModifiers,
                                     clickCount: Int, context: InteractionContext) -> [InteractionEffect] {
        if button == .middle || context.tool == .hand || context.spaceHeld {
            state = .panning(origin: point, viewport: context.viewport)
            return []
        }
        if let type = context.tool.creates {
            state = .creating(type, origin: point)
            return []
        }
        let id: String
        switch hit {
        case .empty:
            state = .marquee(origin: point, base: modifiers.contains(.shift) ? context.selection : [])
            return modifiers.contains(.shift) ? [] : [.select([])]
        case .handle(let target, let handle):
            guard let rect = context.rects[target] else { state = .idle; return [] }
            state = .resizing(Resizing(id: target, handle: handle, origin: point, start: rect, started: false))
            return []
        case .label(let frame):
            if clickCount >= 2 { state = .idle; return [.focus(frame)] }
            id = frame
        case .node(let node):
            if clickCount >= 2, context.selection == [node] {
                state = .idle
                return [.enter(node, CanvasGeometry.screenToWorld(point, viewport: context.viewport))]
            }
            id = node
        }
        if modifiers.contains(.shift) {
            state = .idle
            return [.select(context.selection.symmetricDifference([id]))]
        }
        if context.selection.contains(id), context.selection.count > 1 {
            state = .pressed(Press(origin: point, dragIDs: context.selection, collapseTo: id))
            return []
        }
        state = .pressed(Press(origin: point, dragIDs: [id], collapseTo: nil))
        return context.selection == [id] ? [] : [.select([id])]
    }

    public mutating func pointerDragged(to point: Point, modifiers: PointerModifiers,
                                        context: InteractionContext) -> [InteractionEffect] {
        switch state {
        case .idle:
            return []
        case .pressed(let press):
            let dx = point.x - press.origin.x, dy = point.y - press.origin.y
            guard (dx * dx + dy * dy).squareRoot() > Self.dragThreshold else { return [] }
            let rects = press.dragIDs.filter(context.movable.contains).reduce(into: [String: Rect]()) { $0[$1] = context.rects[$1] }
            guard !rects.isEmpty else {
                // 不能移动的图层（自动布局子项、锁定）拖动时什么都不做。
                state = .pressed(Press(origin: press.origin, dragIDs: [], collapseTo: nil))
                return []
            }
            let moving = Moving(origin: press.origin, startRects: rects, current: [:])
            return [.beginGesture("Move Layers")] + move(moving, to: point, modifiers: modifiers, context: context)
        case .moving(let moving):
            return move(moving, to: point, modifiers: modifiers, context: context)
        case .resizing(var resizing):
            let started = resizing.started
            resizing.started = true
            state = .resizing(resizing)
            let rect = Self.resized(resizing.start, handle: resizing.handle,
                                    by: Point(x: (point.x - resizing.origin.x) / context.viewport.scale,
                                              y: (point.y - resizing.origin.y) / context.viewport.scale))
            return (started ? [] : [.beginGesture("Resize")]) + [.resize(resizing.id, rect)]
        case .marquee(let origin, let base):
            let world = Rect.spanning(CanvasGeometry.screenToWorld(origin, viewport: context.viewport),
                                      CanvasGeometry.screenToWorld(point, viewport: context.viewport))
            let hits = context.marqueeCandidates.filter { context.rects[$0]?.intersects(world) ?? false }
            return [.marquee(Rect.spanning(origin, point)), .select(base.union(hits))]
        case .creating(_, let origin):
            return [.marquee(Rect.spanning(origin, point))]
        case .panning(let origin, let viewport):
            return [.pan(Viewport(x: viewport.x + point.x - origin.x, y: viewport.y + point.y - origin.y, scale: viewport.scale))]
        }
    }

    public mutating func pointerUp(at point: Point, context: InteractionContext) -> [InteractionEffect] {
        finish(at: point, context: context)
    }

    /// 焦点离开时结束手势：进行中的移动或缩放保留当前结果，创建被放弃。
    public mutating func cancel() -> [InteractionEffect] {
        defer { state = .idle }
        switch state {
        case .moving: return [.endGesture, .guides([])]
        case .resizing(let resizing): return resizing.started ? [.endGesture] : []
        case .marquee, .creating: return [.marquee(nil)]
        default: return []
        }
    }

    private mutating func finish(at point: Point, context: InteractionContext) -> [InteractionEffect] {
        defer { state = .idle }
        switch state {
        case .idle, .panning:
            return []
        case .pressed(let press):
            return press.collapseTo.map { [.select([$0])] } ?? []
        case .marquee:
            return [.marquee(nil)]
        case .moving:
            return [.endGesture, .guides([])]
        case .resizing(let resizing):
            return resizing.started ? [.endGesture] : []
        case .creating(let type, let origin):
            let start = CanvasGeometry.screenToWorld(origin, viewport: context.viewport)
            let dx = point.x - origin.x, dy = point.y - origin.y
            let rect: Rect
            if (dx * dx + dy * dy).squareRoot() > Self.dragThreshold {
                rect = Rect.spanning(start, CanvasGeometry.screenToWorld(point, viewport: context.viewport))
            } else {
                rect = Rect(x: start.x, y: start.y, width: Self.defaultSize, height: Self.defaultSize)
            }
            return [.marquee(nil), .create(type, rect)]
        }
    }

    private mutating func move(_ moving: Moving, to point: Point, modifiers: PointerModifiers,
                               context: InteractionContext) -> [InteractionEffect] {
        let scale = context.viewport.scale
        var offset = Point(x: (point.x - moving.origin.x) / scale, y: (point.y - moving.origin.y) / scale)
        var guides: [Guide] = []
        if !modifiers.contains(.control), let union = Rect.union(Array(moving.startRects.values))?.offsetBy(offset) {
            let snapped = Snapping.snap(union, to: context.snapTargets, threshold: Self.snapThreshold / scale)
            offset = offset + snapped.offset
            guides = snapped.guides
        }
        var next = moving
        next.current = moving.startRects.mapValues { Point(x: $0.x + offset.x, y: $0.y + offset.y) }
        state = .moving(next)
        return [.moveNodes(next.current), .guides(guides)]
    }

    /// 按把手拖动距离（画布单位）计算新矩形；尺寸最小为 1，不翻转。
    public static func resized(_ rect: Rect, handle: ResizeHandle, by delta: Point) -> Rect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if handle.movesLeft { left = min(left + delta.x, right - 1) }
        if handle.movesRight { right = max(right + delta.x, left + 1) }
        if handle.movesTop { top = min(top + delta.y, bottom - 1) }
        if handle.movesBottom { bottom = max(bottom + delta.y, top + 1) }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
