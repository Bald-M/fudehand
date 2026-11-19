import Foundation

/// The rules of prototype playback, independent of rendering: where playback starts, which layer a click reaches, how
/// scrolling, layer states, overlays, and visibility toggles change what is shown, and how going to a frame and going back
/// move through the frames shown so far.
public enum Prototype {
    /// Only a top-level frame can be a destination (hidden ones too: playback shows them); an interaction pointing anywhere else does nothing.
    public static func frame(_ id: String, in document: DesignDocument) -> DesignNode? {
        document.nodes.first { $0.id == id && $0.type == .frame }
    }

    /// Checks that every interaction in `node` and its children points at something that exists: a top-level frame of `document`
    /// for navigate and open-overlay, layers of `document` for toggle-visibility. Edits by the Agent are checked this way; a
    /// project file may still hold an interaction whose frame or layer was deleted later, and playback skips it.
    public static func checkDestinations(of node: DesignNode, in document: DesignDocument) throws {
        switch node.interaction {
        case .navigate(let destination, _), .openOverlay(let destination, _, _):
            if frame(destination, in: document) == nil {
                throw DesignError("Layer \(node.id): interaction.destination \(destination) is not a top-level frame")
            }
        case .toggleVisibility(let targets):
            if let missing = targets.first(where: { document.node($0) == nil }) {
                throw DesignError("Layer \(node.id): interaction.targets includes \(missing), which is not a layer")
            }
        case .back, .closeOverlay, nil: break
        }
        for child in node.children { try checkDestinations(of: child, in: document) }
    }

    /// The frame playback starts from: the top-level frame holding the selection (the topmost one when several do), otherwise the first top-level frame.
    public static func startFrame(in document: DesignDocument, selection: Set<String>) -> String? {
        let frames = document.nodes.filter { $0.type == .frame }
        let selected = Set(selection.compactMap { document.ancestry(of: $0).first })
        return (frames.last { selected.contains($0.id) } ?? frames.first)?.id
    }

    /// A layer under a point, with its rectangle relative to the frame's top-left corner.
    public struct Hit: Equatable {
        public let node: DesignNode
        public let rect: Rect
    }

    /// The chain from `frame` down to the topmost visible layer under `point` (relative to the frame's top-left corner). Hidden
    /// layers and everything inside them are never hit, a layer clipped away by a frame cannot be hit, and a group is only hit
    /// through its children. Empty when the point is outside the frame.
    public static func hits(in frame: DesignNode, at point: Point) -> [Hit] {
        guard Rect(x: 0, y: 0, width: frame.width, height: frame.height).contains(point) else { return [] }
        func path(_ node: DesignNode, _ origin: Point) -> [Hit]? {
            let rect = Rect(x: origin.x, y: origin.y, width: node.width, height: node.height)
            let inside = point.x >= rect.minX && point.y >= rect.minY && point.x <= rect.maxX && point.y <= rect.maxY
            if node.type == .frame, node.clipsContent, !inside { return nil }
            for child in node.children.reversed() where child.visible {
                if let below = path(child, Point(x: origin.x + child.x, y: origin.y + child.y)) { return [Hit(node: node, rect: rect)] + below }
            }
            return inside && node.type != .group ? [Hit(node: node, rect: rect)] : nil
        }
        return path(frame, Point(x: 0, y: 0)) ?? []
    }

    /// The layer that answers a click at `point`: the topmost hit layer if it has an interaction, otherwise its nearest ancestor that has one, up to the frame itself.
    public static func responder(in frame: DesignNode, at point: Point) -> DesignNode? {
        hits(in: frame, at: point).last { $0.node.interaction != nil }?.node
    }

    /// How far `frame`'s content can scroll: the extent of its visible children that do not stay fixed (plus the auto layout
    /// padding after them) beyond the frame's size, along its scroll direction only.
    public static func scrollRange(of frame: DesignNode) -> Size {
        guard frame.type == .frame, frame.scroll != .none else { return Size(width: 0, height: 0) }
        let content = frame.children.filter { $0.visible && !$0.fixedOnScroll }
        let right = (content.map { $0.x + $0.width }.max() ?? 0) + (frame.layout?.padding.right ?? 0)
        let bottom = (content.map { $0.y + $0.height }.max() ?? 0) + (frame.layout?.padding.bottom ?? 0)
        return frame.scroll == .vertical ? Size(width: 0, height: max(0, bottom - frame.height))
            : Size(width: max(0, right - frame.width), height: 0)
    }

    /// `node` as playback shows it: toggled layers shown or hidden, the content of scrolled frames moved by their offset while
    /// layers fixed on scroll stay put above it, and layers in a state drawn with that state's look.
    public static func playback(_ node: DesignNode, scroll: [String: Point] = [:], visibility: [String: Bool] = [:],
                                styles: [String: LayerStyle] = [:]) -> DesignNode {
        var result = node
        if let visible = visibility[node.id] { result.visible = visible }
        if let style = styles[node.id] {
            if let fill = style.fill { result.fill = fill }
            if let opacity = style.opacity { result.opacity = opacity }
        }
        result.children = node.children.map { playback($0, scroll: scroll, visibility: visibility, styles: styles) }
        if node.type == .frame, node.scroll != .none {
            let offset = scroll[node.id] ?? Point(x: 0, y: 0)
            var content: [DesignNode] = [], fixed: [DesignNode] = []
            for var child in result.children {
                if child.fixedOnScroll { fixed.append(child); continue }
                child.x -= offset.x
                child.y -= offset.y
                content.append(child)
            }
            result.children = content + fixed
        }
        return result
    }

    /// The look of a layer while hovered and while pressed; pressed applies on top of hover.
    public static func style(of node: DesignNode, hovered: Bool, pressed: Bool) -> LayerStyle? {
        guard let states = node.states else { return nil }
        var style = LayerStyle()
        for layer in [hovered ? states.hover : nil, pressed ? states.pressed : nil].compactMap({ $0 }) {
            if let fill = layer.fill { style.fill = fill }
            if let opacity = layer.opacity { style.opacity = opacity }
        }
        return style == LayerStyle() ? nil : style
    }

    /// The id of the scrim drawn below an overlay frame.
    public static func scrimID(_ frame: String) -> String { "prototype.scrim.\(frame)" }

    /// Where an overlay of `size` sits over a frame of `stage` size: centered, along the bottom edge (centered horizontally), or
    /// with its top-left corner at the bottom-left of the layer that opened it; always kept inside the frame where it fits.
    public static func overlayOrigin(_ position: OverlayPosition, size: Size, stage: Size, trigger: Rect) -> Point {
        let x: Double, y: Double
        switch position {
        case .center: (x, y) = ((stage.width - size.width) / 2, (stage.height - size.height) / 2)
        case .bottom: (x, y) = ((stage.width - size.width) / 2, stage.height - size.height)
        case .belowTrigger: (x, y) = (trigger.minX, trigger.maxY)
        }
        func clamp(_ value: Double, _ length: Double, _ limit: Double) -> Double { max(0, min(value, limit - length)) }
        return Point(x: clamp(x, size.width, stage.width), y: clamp(y, size.height, stage.height))
    }
}

/// An overlay open in the prototype window: a top-level frame shown over the frame on show, and how it was opened.
public struct PrototypeOverlay: Equatable {
    public let frame: String
    public let settings: OverlaySettings
    public let transition: PrototypeTransition
    /// The rectangle of the layer that opened it, in the coordinates of the frame on show.
    public let trigger: Rect
    public init(frame: String, settings: OverlaySettings, transition: PrototypeTransition, trigger: Rect) {
        self.frame = frame; self.settings = settings; self.transition = transition; self.trigger = trigger
    }
}

/// One playback session in the preview window: the frame shown, the frames that led to it, the overlays open over it, and the
/// scroll offsets and visibility toggles of this playback, which never touch the design document.
public struct PrototypePlayer: Equatable {
    /// A move from one frame to another, played with `transition`; `reversed` plays it backwards, as going back does.
    public struct Step: Equatable {
        public let from: String
        public let to: String
        public let transition: PrototypeTransition
        public let reversed: Bool
        public init(from: String, to: String, transition: PrototypeTransition, reversed: Bool) {
            self.from = from; self.to = to; self.transition = transition; self.reversed = reversed
        }
    }

    /// What an interaction changed, for the window to show.
    public enum Effect: Equatable {
        case move(Step)
        case openOverlay(PrototypeOverlay)
        case closeOverlay(PrototypeOverlay)
        case toggle
    }

    /// The layers under a point in the frame that takes input: the one answering a click and the one showing states.
    public struct Target: Equatable {
        public var responder: Prototype.Hit?
        public var styled: String?
        /// The point is outside the topmost overlay, where a click may close it.
        public var outside: Bool
        public init(responder: Prototype.Hit? = nil, styled: String? = nil, outside: Bool = false) {
            self.responder = responder; self.styled = styled; self.outside = outside
        }
    }

    private struct Visit: Equatable {
        let frame: String
        /// The transition that left this frame for the next one; going back plays it in reverse.
        let transition: PrototypeTransition
    }

    public private(set) var current: String
    private var history: [Visit] = []
    /// Bottom to top.
    public private(set) var overlays: [PrototypeOverlay] = []
    /// An overlay playing its closing transition: still rendered, on top, but it no longer takes input.
    public private(set) var closing: PrototypeOverlay?
    /// By scrolling frame id.
    public private(set) var scrollOffsets: [String: Point] = [:]
    /// Layers whose visibility a toggle changed, by id.
    public private(set) var visibility: [String: Bool] = [:]
    /// Set while a transition plays: clicks in the meantime are ignored, so a transition is never cut short or queued.
    public private(set) var isTransitioning = false

    public init(start: String) { current = start }

    // MARK: What is shown

    /// The frame on show and the open overlays (with the closing one when `includingClosing`), each paired with its origin on
    /// the stage. Overlays whose frame was deleted are left out.
    private func placed(in document: DesignDocument, includingClosing: Bool = false) -> [(overlay: PrototypeOverlay?, frame: DesignNode, origin: Point)] {
        guard let base = Prototype.frame(current, in: document) else { return [] }
        let stage = Size(width: base.width, height: base.height)
        let shown = overlays + (includingClosing ? [closing].compactMap { $0 } : [])
        return [(nil, base, Point(x: 0, y: 0))] + shown.compactMap { overlay in
            Prototype.frame(overlay.frame, in: document).map { frame in
                (overlay, frame, Prototype.overlayOrigin(overlay.settings.position, size: Size(width: frame.width, height: frame.height),
                                                         stage: stage, trigger: overlay.trigger))
            }
        }
    }

    private func tree(_ frame: DesignNode, styles: [String: LayerStyle] = [:]) -> DesignNode {
        Prototype.playback(frame, scroll: scrollOffsets, visibility: visibility, styles: styles)
    }

    /// The layers to render, bottom to top: the frame on show at the origin, then for each overlay its scrim (when it has a
    /// background) covering the frame on show, and the overlay frame at its origin; an overlay that is closing stays on top until
    /// its transition ends. All are visible whatever their own setting.
    public func scene(in document: DesignDocument, styles: [String: LayerStyle] = [:]) -> [DesignNode] {
        let placed = placed(in: document, includingClosing: true)
        guard let base = placed.first?.frame else { return [] }
        return placed.flatMap { item -> [DesignNode] in
            var frame = tree(item.frame, styles: styles)
            frame.x = item.origin.x
            frame.y = item.origin.y
            frame.visible = true
            guard let background = item.overlay?.settings.background else { return [frame] }
            var scrim = DesignNode(id: Prototype.scrimID(item.frame.id), type: .rectangle, width: base.width, height: base.height)
            scrim.fill = background
            return [scrim, frame]
        }
    }

    /// The hit chain in the topmost frame (with rectangles in stage coordinates), or nil when the point is outside the topmost
    /// overlay, where nothing below takes input.
    private func hits(at point: Point, in document: DesignDocument) -> [Prototype.Hit]? {
        guard let top = placed(in: document).last else { return [] }
        let local = point - top.origin
        if top.overlay != nil, !Rect(x: 0, y: 0, width: top.frame.width, height: top.frame.height).contains(local) { return nil }
        return Prototype.hits(in: tree(top.frame), at: local).map { Prototype.Hit(node: $0.node, rect: $0.rect.offsetBy(top.origin)) }
    }

    public func target(at point: Point, in document: DesignDocument) -> Target {
        guard let chain = hits(at: point, in: document) else { return Target(outside: true) }
        return Target(responder: chain.last { $0.node.interaction != nil }, styled: chain.last { $0.node.states != nil }?.node.id)
    }

    // MARK: Input

    /// A click at `point` in stage coordinates (the frame on show's top-left is the origin); returns what changed, or nil when the click does nothing.
    /// With an overlay open, only that overlay takes clicks; a click outside it closes it when its settings say so.
    public mutating func click(at point: Point, in document: DesignDocument) -> Effect? {
        guard !isTransitioning else { return nil }
        guard let chain = hits(at: point, in: document) else {
            return overlays.last?.settings.closeOnOutsideClick == true ? closeOverlay() : nil
        }
        guard let responder = chain.last(where: { $0.node.interaction != nil }), let interaction = responder.node.interaction else { return nil }
        return perform(interaction, trigger: responder.rect, in: document)
    }

    /// Performs an interaction; `trigger` is the rectangle of the layer that fired it, in stage coordinates.
    public mutating func perform(_ interaction: DesignInteraction, trigger: Rect = Rect(x: 0, y: 0, width: 0, height: 0),
                                 in document: DesignDocument) -> Effect? {
        guard !isTransitioning else { return nil }
        switch interaction {
        case .navigate(let destination, let transition):
            guard let frame = Prototype.frame(destination, in: document) else { return nil }
            overlays = []
            history.append(Visit(frame: current, transition: transition))
            resetScroll(in: frame)
            return .move(begin(Step(from: current, to: destination, transition: transition, reversed: false)))
        case .back:
            if !overlays.isEmpty { return closeOverlay() }
            // Frames deleted since they were shown are skipped.
            while let visit = history.popLast() {
                if Prototype.frame(visit.frame, in: document) != nil {
                    return .move(begin(Step(from: current, to: visit.frame, transition: visit.transition, reversed: true)))
                }
            }
            return nil
        case .openOverlay(let destination, let settings, let transition):
            // A frame already on show cannot be opened over itself.
            guard let frame = Prototype.frame(destination, in: document), destination != current,
                  !overlays.contains(where: { $0.frame == destination }) else { return nil }
            let overlay = PrototypeOverlay(frame: destination, settings: settings, transition: transition, trigger: trigger)
            overlays.append(overlay)
            resetScroll(in: frame)
            isTransitioning = Self.animates(transition)
            return .openOverlay(overlay)
        case .closeOverlay:
            return closeOverlay()
        case .toggleVisibility(let targets):
            var changed = false
            for id in Set(targets) {
                guard let node = document.node(id) else { continue }
                visibility[id] = !(visibility[id] ?? node.visible)
                changed = true
            }
            return changed ? .toggle : nil
        }
    }

    private mutating func closeOverlay() -> Effect? {
        guard let overlay = overlays.popLast() else { return nil }
        isTransitioning = Self.animates(overlay.transition)
        if isTransitioning { closing = overlay }
        return .closeOverlay(overlay)
    }

    /// Scrolls the innermost scrolling frame under `point` that can move along `delta` (in content offset terms: positive moves
    /// further into the content), clamped to its range. A mouse wheel (`wheel`), which only turns vertically, scrolls a
    /// horizontal frame with its vertical delta; a trackpad's vertical swipe passes a horizontal frame by. Returns whether anything moved.
    public mutating func scroll(by delta: Point, at point: Point, wheel: Bool = false, in document: DesignDocument) -> Bool {
        guard let chain = hits(at: point, in: document) else { return false }
        for hit in chain.reversed() where hit.node.type == .frame && hit.node.scroll != .none {
            // The hit chain holds playback copies; the range comes from the frame's own children (with toggles applied).
            guard let original = document.node(hit.node.id) else { continue }
            let range = Prototype.scrollRange(of: Prototype.playback(original, visibility: visibility))
            let amount = hit.node.scroll == .vertical ? delta.y : (wheel && delta.x == 0 ? delta.y : delta.x)
            let old = scrollOffsets[hit.node.id] ?? Point(x: 0, y: 0)
            var next = old
            if hit.node.scroll == .vertical { next.y = min(max(old.y + amount, 0), range.height) }
            else { next.x = min(max(old.x + amount, 0), range.width) }
            guard next != old else { continue }
            scrollOffsets[hit.node.id] = next
            return true
        }
        return false
    }

    /// A frame arrived at starts scrolled to the top, as do the frames inside it.
    private mutating func resetScroll(in frame: DesignNode) {
        DesignDocument(nodes: [frame]).forEach { scrollOffsets[$0.id] = nil }
    }

    private static func animates(_ transition: PrototypeTransition) -> Bool { transition.type != .none && transition.duration > 0 }

    private mutating func begin(_ step: Step) -> Step {
        current = step.to
        isTransitioning = Self.animates(step.transition)
        return step
    }

    /// Called when the transition of the last step or overlay has finished playing.
    public mutating func finishTransition() {
        isTransitioning = false
        closing = nil
    }
}
