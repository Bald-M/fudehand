import Foundation

public enum CanvasTool: String, Equatable { case move, hand }

public enum HitTarget: Equatable { case empty, frameHeader(String), frameContent(String) }

public enum PointerButton: Equatable { case primary, middle }

public struct PointerModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = PointerModifiers(rawValue: 1 << 0)
    public static let control = PointerModifiers(rawValue: 1 << 1)
}

public enum InteractionEffect: Equatable {
    case select(Set<String>)
    /// Live frame origins (top-left, world coordinates).
    case moveFrames([String: Point])
    case commitMove(from: [String: Point], to: [String: Point])
    /// Screen-space marquee rectangle; nil hides it.
    case marquee(Rect?)
    /// Alignment guides in world coordinates.
    case guides([Guide])
    case pan(Viewport)
    /// Double-clicked header: zoom to this frame.
    case focus(String)
}

public struct InteractionContext {
    public var viewport: Viewport
    /// World-space frame rects, including header height.
    public var frames: [String: Rect]
    public var selection: Set<String>
    public var tool: CanvasTool
    public var spaceHeld: Bool
    /// Frames whose pages have loaded and can receive web input.
    public var activatable: Set<String>

    public init(viewport: Viewport, frames: [String: Rect], selection: Set<String>,
                tool: CanvasTool, spaceHeld: Bool, activatable: Set<String>) {
        self.viewport = viewport; self.frames = frames; self.selection = selection
        self.tool = tool; self.spaceHeld = spaceHeld; self.activatable = activatable
    }
}

public struct CanvasInteraction {
    public static let dragThreshold = 3.0
    public static let snapThreshold = 6.0

    private struct Press {
        var origin: Point
        var dragIDs: Set<String>
        /// Set when pressing page content inside a multi-selection: a click collapses to this id.
        var collapseTo: String?
    }

    private struct Moving {
        var origin: Point
        var startRects: [String: Rect]
        var current: [String: Point]
        var start: [String: Point] { startRects.mapValues { Point(x: $0.x, y: $0.y) } }
    }

    private enum State {
        case idle
        case pressed(Press)
        case movingFrames(Moving)
        case marquee(origin: Point, base: Set<String>)
        case panning(origin: Point, viewport: Viewport)
    }

    private var state = State.idle

    public init() {}

    public var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    public static func pageReceivesPointer(hit: HitTarget, button: PointerButton, context: InteractionContext) -> Bool {
        guard button == .primary, context.tool == .move, !context.spaceHeld,
              case .frameContent(let id) = hit,
              context.selection == [id], context.activatable.contains(id) else { return false }
        return true
    }

    public mutating func pointerDown(at point: Point, hit: HitTarget, button: PointerButton, modifiers: PointerModifiers,
                                     clickCount: Int, context: InteractionContext) -> [InteractionEffect] {
        // A previous gesture whose mouse-up was missed is finished first.
        let leftover = isIdle ? [] : finish()
        return leftover + beginPress(at: point, hit: hit, button: button, modifiers: modifiers,
                                     clickCount: clickCount, context: context)
    }

    private mutating func beginPress(at point: Point, hit: HitTarget, button: PointerButton, modifiers: PointerModifiers,
                                     clickCount: Int, context: InteractionContext) -> [InteractionEffect] {
        if button == .middle || context.tool == .hand || context.spaceHeld {
            state = .panning(origin: point, viewport: context.viewport)
            return []
        }
        let id: String
        let isContent: Bool
        switch hit {
        case .empty:
            state = .marquee(origin: point, base: modifiers.contains(.shift) ? context.selection : [])
            return modifiers.contains(.shift) ? [] : [.select([])]
        case .frameHeader(let frame):
            if clickCount >= 2 { state = .idle; return [.focus(frame)] }
            id = frame; isContent = false
        case .frameContent(let frame):
            id = frame; isContent = true
        }
        if modifiers.contains(.shift) {
            state = .idle
            return [.select(context.selection.symmetricDifference([id]))]
        }
        if context.selection.contains(id), context.selection.count > 1 {
            state = .pressed(Press(origin: point, dragIDs: context.selection, collapseTo: isContent ? id : nil))
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
            let rects = press.dragIDs.reduce(into: [String: Rect]()) { $0[$1] = context.frames[$1] }
            guard !rects.isEmpty else { return [] }
            let moving = Moving(origin: press.origin, startRects: rects, current: [:])
            state = .movingFrames(moving)
            return move(moving, to: point, modifiers: modifiers, context: context)
        case .movingFrames(let moving):
            return move(moving, to: point, modifiers: modifiers, context: context)
        case .marquee(let origin, let base):
            let screen = Rect.spanning(origin, point)
            let a = CanvasGeometry.screenToWorld(origin, viewport: context.viewport)
            let b = CanvasGeometry.screenToWorld(point, viewport: context.viewport)
            let world = Rect.spanning(a, b)
            let hits = context.frames.filter { $0.value.intersects(world) }.keys
            return [.marquee(screen), .select(base.union(hits))]
        case .panning(let origin, let viewport):
            return [.pan(Viewport(x: viewport.x + point.x - origin.x, y: viewport.y + point.y - origin.y,
                                  scale: viewport.scale))]
        }
    }

    public mutating func pointerUp(at point: Point, context: InteractionContext) -> [InteractionEffect] {
        finish()
    }

    public mutating func cancel() -> [InteractionEffect] {
        switch state {
        case .movingFrames, .marquee: return finish()
        default:
            state = .idle
            return []
        }
    }

    private mutating func finish() -> [InteractionEffect] {
        defer { state = .idle }
        switch state {
        case .idle, .panning:
            return []
        case .pressed(let press):
            return press.collapseTo.map { [.select([$0])] } ?? []
        case .marquee:
            return [.marquee(nil)]
        case .movingFrames(let moving):
            guard !moving.current.isEmpty else { return [] }
            guard moving.current != moving.start else { return [.guides([])] }
            return [.commitMove(from: moving.start, to: moving.current), .guides([])]
        }
    }

    private mutating func move(_ moving: Moving, to point: Point, modifiers: PointerModifiers,
                               context: InteractionContext) -> [InteractionEffect] {
        let scale = context.viewport.scale
        var offset = Point(x: (point.x - moving.origin.x) / scale, y: (point.y - moving.origin.y) / scale)
        var guides: [Guide] = []
        if !modifiers.contains(.control),
           let union = Rect.union(Array(moving.startRects.values))?.offsetBy(offset) {
            let others = context.frames.filter { moving.startRects[$0.key] == nil }.map(\.value)
            let snapped = Snapping.snap(union, to: others, threshold: Self.snapThreshold / scale)
            offset = offset + snapped.offset
            guides = snapped.guides
        }
        var next = moving
        next.current = moving.startRects.mapValues { Point(x: $0.x + offset.x, y: $0.y + offset.y) }
        state = .movingFrames(next)
        return [.moveFrames(next.current), .guides(guides)]
    }
}
