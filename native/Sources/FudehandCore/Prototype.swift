import Foundation

/// The rules of prototype playback, independent of rendering: where playback starts, which layer a click reaches, and how
/// going to a frame and going back move through the frames shown so far.
public enum Prototype {
    /// Only a top-level frame can be a destination (hidden ones too: playback shows them); an interaction pointing anywhere else does nothing.
    public static func frame(_ id: String, in document: DesignDocument) -> DesignNode? {
        document.nodes.first { $0.id == id && $0.type == .frame }
    }

    /// Checks that every interaction in `node` and its children goes to a top-level frame of `document`. Edits by the Agent are
    /// checked this way; a project file may still hold an interaction whose frame was deleted later, and playback skips it.
    public static func checkDestinations(of node: DesignNode, in document: DesignDocument) throws {
        if case .navigate(let destination, _) = node.interaction, frame(destination, in: document) == nil {
            throw DesignError("Layer \(node.id): interaction.destination \(destination) is not a top-level frame")
        }
        for child in node.children { try checkDestinations(of: child, in: document) }
    }

    /// The frame playback starts from: the top-level frame holding the selection (the topmost one when several do), otherwise the first top-level frame.
    public static func startFrame(in document: DesignDocument, selection: Set<String>) -> String? {
        let frames = document.nodes.filter { $0.type == .frame }
        let selected = Set(selection.compactMap { document.ancestry(of: $0).first })
        return (frames.last { selected.contains($0.id) } ?? frames.first)?.id
    }

    /// The layer that answers a click at `point` (relative to the frame's top-left corner): the topmost visible layer under the
    /// point if it has an interaction, otherwise its nearest ancestor that has one, up to the frame itself. Hidden layers and
    /// everything inside them never answer, and a layer clipped away by a frame cannot be hit.
    public static func responder(in frame: DesignNode, at point: Point) -> DesignNode? {
        guard Rect(x: 0, y: 0, width: frame.width, height: frame.height).contains(point) else { return nil }
        /// The chain from `node` down to the topmost hit layer, or nil when nothing inside `node` is hit and `node` itself is not.
        func path(_ node: DesignNode, _ local: Point) -> [DesignNode]? {
            let inside = local.x >= 0 && local.y >= 0 && local.x <= node.width && local.y <= node.height
            if node.type == .frame, node.clipsContent, !inside { return nil }
            for child in node.children.reversed() where child.visible {
                if let below = path(child, Point(x: local.x - child.x, y: local.y - child.y)) { return [node] + below }
            }
            // A group is only hit through its children.
            return inside && node.type != .group ? [node] : nil
        }
        return path(frame, point)?.last { $0.interaction != nil }
    }
}

/// One playback session in the preview window: the frame shown and the frames that led to it.
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

    private struct Visit: Equatable {
        let frame: String
        /// The transition that left this frame for the next one; going back plays it in reverse.
        let transition: PrototypeTransition
    }

    public private(set) var current: String
    private var history: [Visit] = []
    /// Set while a transition plays: clicks in the meantime are ignored, so a transition is never cut short or queued.
    public private(set) var isTransitioning = false

    public init(start: String) { current = start }

    public var canGoBack: Bool { !history.isEmpty }

    /// A click at `point` in the current frame's coordinates; returns the step to play, or nil when the click does nothing.
    public mutating func click(at point: Point, in document: DesignDocument) -> Step? {
        guard !isTransitioning, let frame = Prototype.frame(current, in: document),
              let interaction = Prototype.responder(in: frame, at: point)?.interaction else { return nil }
        return perform(interaction, in: document)
    }

    public mutating func perform(_ interaction: DesignInteraction, in document: DesignDocument) -> Step? {
        guard !isTransitioning else { return nil }
        switch interaction {
        case .navigate(let destination, let transition):
            guard Prototype.frame(destination, in: document) != nil else { return nil }
            history.append(Visit(frame: current, transition: transition))
            return begin(Step(from: current, to: destination, transition: transition, reversed: false))
        case .back:
            // Frames deleted since they were shown are skipped.
            while let visit = history.popLast() {
                if Prototype.frame(visit.frame, in: document) != nil {
                    return begin(Step(from: current, to: visit.frame, transition: visit.transition, reversed: true))
                }
            }
            return nil
        }
    }

    private mutating func begin(_ step: Step) -> Step {
        current = step.to
        isTransitioning = step.transition.type != .none && step.transition.duration > 0
        return step
    }

    /// Called when the transition of the last step has finished playing.
    public mutating func finishTransition() { isTransitioning = false }
}
