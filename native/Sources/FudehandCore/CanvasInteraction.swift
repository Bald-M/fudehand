import Foundation

public enum CanvasTool: String, Equatable, CaseIterable, Sendable {
    case move, hand, frame, rectangle, ellipse, text, annotate

    /// The layer type a creation tool corresponds to.
    public var creates: NodeType? {
        switch self {
        case .frame: return .frame
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .move, .hand, .annotate: return nil
        }
    }
}

/// The eight resize handles on the selection box.
public enum ResizeHandle: CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// The handle's relative position on the rectangle (0, 0.5, 1).
    public var anchor: Point {
        Point(x: movesLeft ? 0 : movesRight ? 1 : 0.5, y: movesTop ? 0 : movesBottom ? 1 : 0.5)
    }
}

/// The target under the pointer; `node` has already been resolved by the App, according to the current selection level, to a selectable layer.
public enum HitTarget: Equatable, Sendable {
    case empty
    case node(String)
    /// The name label above a top-level frame.
    case label(String)
    case handle(String, ResizeHandle)
    /// An annotation marker; markers sit above everything else on the canvas.
    case annotation(String)
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
    /// Begins a continuous edit; the name is used as the undo step name.
    case beginGesture(String)
    /// The top-left corners of the layers being dragged (absolute canvas coordinates).
    case moveNodes([String: Point])
    /// The rectangles of the layers being resized (absolute canvas coordinates).
    case resize(String, Rect)
    case endGesture
    /// The marquee selection or creation preview rectangle in screen coordinates; nil hides it.
    case marquee(Rect?)
    /// Snapping guides in canvas coordinates.
    case guides([Guide])
    case pan(Viewport)
    /// Double-clicking a top-level frame's label: zoom to focus.
    case focus(String)
    /// Double-clicking a selected layer: the App selects the layer one level deeper under the pointer (canvas coordinates).
    case enter(String, Point)
    /// Creation tool: creates a layer at a rectangle in canvas coordinates. `clicked` is true for a single click (default size) and false for a dragged-out size.
    case create(NodeType, Rect, clicked: Bool)
    /// Pressing an annotation marker: expands its thread, or collapses it when it is the one already expanded.
    case toggleAnnotation(String)
    /// Annotate tool: starts a new annotation on a layer at a point in canvas coordinates.
    case annotate(String, Point)
}

public struct InteractionContext {
    public var viewport: Viewport
    /// The absolute canvas rectangles of the selected layers and the top-level layers.
    public var rects: [String: Rect]
    /// The candidate layers for marquee selection (top-level layers).
    public var marqueeCandidates: Set<String>
    /// The rectangles the current selection can snap to while dragged (sibling layers and the parent layer).
    public var snapTargets: [Rect]
    /// The layers that can be moved by dragging (not in auto layout, not locked).
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

/// A state machine turning pointer events into canvas effects; no AppKit dependency.
public struct CanvasInteraction {
    public static let dragThreshold = 3.0
    public static let snapThreshold = 6.0
    /// The default size when creating with a single click (no size dragged out).
    public static let defaultSize = 100.0

    private struct Press {
        var origin: Point
        var dragIDs: Set<String>
        /// When pressed inside a multi-selection (without Shift) and not dragged, the selection collapses to this layer on release.
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
        // End the previous gesture first if its release event was missed.
        let leftover = isIdle ? [] : finish(at: point, context: context)
        return leftover + beginPress(at: point, hit: hit, button: button, modifiers: modifiers, clickCount: clickCount, context: context)
    }

    private mutating func beginPress(at point: Point, hit: HitTarget, button: PointerButton, modifiers: PointerModifiers,
                                     clickCount: Int, context: InteractionContext) -> [InteractionEffect] {
        if button == .middle || context.tool == .hand || context.spaceHeld {
            state = .panning(origin: point, viewport: context.viewport)
            return []
        }
        if case .annotation(let id) = hit {
            state = .idle
            return [.toggleAnnotation(id)]
        }
        if let type = context.tool.creates {
            state = .creating(type, origin: point)
            return []
        }
        if context.tool == .annotate {
            state = .idle
            guard case .node(let id) = hit else { return [] }
            return [.annotate(id, CanvasGeometry.screenToWorld(point, viewport: context.viewport))]
        }
        let id: String
        switch hit {
        case .annotation: return []
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
                // Dragging layers that cannot be moved (auto layout children, locked) does nothing.
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

    /// Ends the gesture when focus leaves: a move or resize in progress keeps its current result, and a creation is abandoned.
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
            guard (dx * dx + dy * dy).squareRoot() > Self.dragThreshold else {
                let rect = Rect(x: start.x, y: start.y, width: Self.defaultSize, height: Self.defaultSize)
                return [.marquee(nil), .create(type, rect, clicked: true)]
            }
            // A straight-line drag still yields a visible layer, matching the resize handles' minimum of 1.
            var rect = Rect.spanning(start, CanvasGeometry.screenToWorld(point, viewport: context.viewport))
            rect.width = max(rect.width, 1)
            rect.height = max(rect.height, 1)
            return [.marquee(nil), .create(type, rect, clicked: false)]
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

    /// Computes the new rectangle from the distance the handle was dragged (canvas units); the size is at least 1 and never flips.
    public static func resized(_ rect: Rect, handle: ResizeHandle, by delta: Point) -> Rect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if handle.movesLeft { left = min(left + delta.x, right - 1) }
        if handle.movesRight { right = max(right + delta.x, left + 1) }
        if handle.movesTop { top = min(top + delta.y, bottom - 1) }
        if handle.movesBottom { bottom = max(bottom + delta.y, top + 1) }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
