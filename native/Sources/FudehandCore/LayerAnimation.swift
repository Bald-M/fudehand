import Foundation

/// What a layer animation does. Entrances play when the layer's frame appears; loops keep going while it is on show.
public enum AnimationType: String, Sendable, CaseIterable {
    case fadeIn = "fade-in", slideIn = "slide-in", scaleIn = "scale-in", spin, pulse, shimmer

    public var isEntrance: Bool { self == .fadeIn || self == .slideIn || self == .scaleIn }
}

/// The side a slide-in comes in from.
public enum AnimationEdge: String, Sendable, CaseIterable { case left, right, top, bottom }

/// What a pulse changes back and forth.
public enum PulseProperty: String, Sendable, CaseIterable { case scale, opacity }

/// A layer's animation in prototype playback. It only changes how the layer is shown while playing or previewing, never the
/// design document; the editing canvas and snapshots show the layer still.
public struct LayerAnimation: Equatable, Sendable {
    public var type: AnimationType
    /// Slide-in only.
    public var from: AnimationEdge
    /// Slide-in only: how far away, in pt, the layer starts.
    public var distance: Double
    /// Pulse only.
    public var property: PulseProperty
    /// Seconds; one cycle for a loop.
    public var duration: Double
    /// Seconds before the first cycle.
    public var delay: Double
    public var easing: TransitionEasing
    /// How many times it plays; nil is forever.
    public var repeatCount: Int?

    /// An animation of `type` with that type's defaults.
    public init(type: AnimationType) {
        self.type = type
        from = .bottom
        distance = 40
        property = .scale
        duration = type.isEntrance ? 0.3 : type == .shimmer ? 1.5 : 1
        delay = 0
        easing = type.isEntrance ? .easeOut : type == .pulse ? .easeInOut : .linear
        repeatCount = type.isEntrance ? 1 : nil
    }

    public static let maximumDuration = 60.0
    public static let maximumDelay = 60.0
    public static let maximumDistance = 10_000.0
    public static let maximumRepeat = 1000

    /// The visible layers in `node` (itself included) that have an animation, in drawing order. Hidden layers and everything in
    /// them do not animate.
    public static func animated(in node: DesignNode) -> [(id: String, animation: LayerAnimation)] {
        guard node.visible else { return [] }
        let own = node.animation.map { [(id: node.id, animation: $0)] } ?? []
        return own + node.children.flatMap { animated(in: $0) }
    }
}

/// A text layer's text sequence: contents shown one after another at a fixed interval during playback, to look like a countdown
/// or a changing number. Appearance only: it triggers nothing when it ends.
public struct TextSequence: Hashable, Sendable {
    public var items: [String]
    /// Seconds each item stays.
    public var interval: Double
    /// Whether it starts over after the last item; otherwise the last item stays.
    public var loop: Bool

    public init(items: [String], interval: Double = 1, loop: Bool = false) {
        self.items = items; self.interval = interval; self.loop = loop
    }

    public static let minimumInterval = 0.05
    public static let maximumInterval = 3600.0
    public static let maximumItems = 1000

    /// Step `elapsed / interval`, with a little slack so a timer firing a hair early still lands on the step it was set for.
    private func step(_ elapsed: Double) -> Int { Int((max(elapsed, 0) / interval + 1e-9).rounded(.down)) }

    /// The item shown `elapsed` seconds after the sequence started.
    public func index(at elapsed: Double) -> Int {
        let step = step(elapsed)
        return loop ? step % items.count : min(step, items.count - 1)
    }

    /// When the shown item next changes, in seconds since the start; nil when it never does again.
    public func nextChange(after elapsed: Double) -> Double? {
        let step = step(elapsed)
        guard items.count > 1, loop || step < items.count - 1 else { return nil }
        return Double(step + 1) * interval
    }

    /// Whether any visible text layer in `node` has a sequence.
    public static func hasSequences(in node: DesignNode) -> Bool {
        node.visible && (node.text?.sequence != nil || node.children.contains { hasSequences(in: $0) })
    }

    /// The earliest time after `elapsed` at which a sequence in `node` changes; nil when none ever does again.
    public static func nextChange(in node: DesignNode, after elapsed: Double) -> Double? {
        guard node.visible else { return nil }
        let own = node.text?.sequence?.nextChange(after: elapsed)
        return node.children.compactMap { nextChange(in: $0, after: elapsed) }.reduce(own) { min($0 ?? $1, $1) }
    }

    /// `node` as playback shows it `elapsed` seconds after its frame appeared: every sequence shows its current item with the
    /// layer's own text style, and the layout runs again so auto-sized text and auto layout parents fit the new contents.
    public static func playing(_ node: DesignNode, at elapsed: Double, measure: TextMeasure) -> DesignNode {
        func substitute(_ node: inout DesignNode) {
            if let sequence = node.text?.sequence { node.text?.content = sequence.items[sequence.index(at: elapsed)] }
            for index in node.children.indices { substitute(&node.children[index]) }
        }
        var nodes = [node]
        substitute(&nodes[0])
        DesignLayout.apply(to: &nodes, measure: measure)
        return nodes[0]
    }
}
