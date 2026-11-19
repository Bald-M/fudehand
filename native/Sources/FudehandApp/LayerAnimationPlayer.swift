import AppKit
import FudehandCore

/// Plays the layer animations and text sequences of one subtree on a renderer's layers, for the prototype window and the
/// animation preview. Core Animation runs the animations; nothing here touches the design document, and the editing canvas never
/// uses it, so it stays still.
@MainActor
final class LayerAnimationPlayer {
    private let renderer: DesignRenderer
    /// Layers that got an animation, and those that also got a shimmer mask.
    private var animated: [String] = []
    private var masked: [String: CALayer] = [:]
    /// The media time the subtree appeared at: the clock of its text sequences.
    private var begin: CFTimeInterval?
    private var subtree: DesignNode?
    private var timer: Timer?
    /// Called when a text sequence moves to its next item; the owner renders `playing(_:)` again.
    var redraw: () -> Void = {}

    static let key = "fudehand.animation"

    init(renderer: DesignRenderer) { self.renderer = renderer }

    /// `node` as it shows now: the current item of every text sequence, laid out again. Unchanged when it has no sequence or the
    /// player is stopped.
    func playing(_ node: DesignNode) -> DesignNode {
        guard let begin, TextSequence.hasSequences(in: node) else { return node }
        return TextSequence.playing(node, at: CACurrentMediaTime() - begin, measure: TextMetrics.measure)
    }

    /// Starts the animations of `node`, already rendered, and its text sequences. They begin after `wait` seconds (the transition
    /// bringing the frame in); until then entrance layers wait in their starting state.
    func start(_ node: DesignNode, after wait: Double = 0) {
        stop()
        let now = CACurrentMediaTime()
        begin = now + wait
        subtree = node
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, animation) in LayerAnimation.animated(in: node) {
            guard let layer = renderer.layer(for: id) else { continue }
            if let mask = Self.add(animation, to: layer, at: now + wait + animation.delay) { masked[id] = mask }
            animated.append(id)
        }
        CATransaction.commit()
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let wasSequenced = begin != nil && subtree.map(TextSequence.hasSequences) == true
        begin = nil
        subtree = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in animated { renderer.layer(for: id)?.removeAnimation(forKey: Self.key) }
        for (id, mask) in masked where renderer.layer(for: id)?.mask === mask { renderer.layer(for: id)?.mask = nil }
        CATransaction.commit()
        animated = []
        masked = [:]
        // Back to the layers' own contents.
        if wasSequenced { redraw() }
    }

    /// Wakes up when the next sequence item is due.
    private func schedule() {
        guard let begin, let subtree, let next = TextSequence.nextChange(in: subtree, after: CACurrentMediaTime() - begin) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(begin + next - CACurrentMediaTime(), 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.redraw()
                self.schedule()
            }
        }
    }

    // MARK: Animations

    static func timing(_ easing: TransitionEasing) -> CAMediaTimingFunction {
        CAMediaTimingFunction(name: PrototypeStageView.timing(easing))
    }

    /// Adds the Core Animation for `animation` to `layer`, beginning at media time `start`. Returns the mask it put on the layer, if any.
    @discardableResult
    static func add(_ animation: LayerAnimation, to layer: CALayer, at start: CFTimeInterval) -> CALayer? {
        let opacity = layer.opacity
        func basic(_ keyPath: String, from: Any, to: Any? = nil) -> CABasicAnimation {
            let value = CABasicAnimation(keyPath: keyPath)
            value.fromValue = from
            value.toValue = to
            return value
        }
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let value = CAKeyframeAnimation(keyPath: keyPath)
            value.values = values
            value.timingFunctions = Array(repeating: timing(animation.easing), count: values.count - 1)
            return value
        }
        let fade = basic("opacity", from: 0, to: opacity)
        let parts: [CAAnimation]
        var mask: CAGradientLayer?
        switch animation.type {
        case .fadeIn:
            parts = [fade]
        case .slideIn:
            let d = animation.distance
            let offset: CGPoint = switch animation.from {
            case .left: CGPoint(x: -d, y: 0)
            case .right: CGPoint(x: d, y: 0)
            case .top: CGPoint(x: 0, y: -d)
            case .bottom: CGPoint(x: 0, y: d)
            }
            let move = basic("position", from: NSValue(point: offset), to: NSValue(point: .zero))
            move.isAdditive = true
            parts = [move, fade]
        case .scaleIn:
            parts = [basic("transform.scale", from: 0.8, to: 1), fade]
        case .spin:
            parts = [basic("transform.rotation.z", from: 0, to: 2 * Double.pi)]
        case .pulse:
            parts = [animation.property == .scale ? keyframes("transform.scale", [1, 1.1, 1])
                                                  : keyframes("opacity", [opacity, opacity * 0.4, opacity])]
        case .shimmer:
            // A band sweeps across, letting what is behind show through: a mask three times as wide as the layer, see-through
            // only in its middle, moves from left of the layer to right of it. Masking keeps the layer's own shape and covers its
            // children too.
            let width = layer.bounds.width
            let band = CAGradientLayer()
            band.actions = DesignRenderer.noActions
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            let solid = CGColor(gray: 0, alpha: 1), faint = CGColor(gray: 0, alpha: 0.45)
            band.colors = [solid, solid, faint, solid, solid]
            band.locations = [0, 0.43, 0.5, 0.57, 1]
            band.bounds = CGRect(x: 0, y: 0, width: width * 3, height: layer.bounds.height)
            band.position = CGPoint(x: -0.3 * width, y: layer.bounds.height / 2)
            layer.mask = band
            mask = band
            parts = [basic("position.x", from: -0.3 * width, to: 1.3 * width)]
        }
        let group = CAAnimationGroup()
        group.animations = parts
        // A pulse eases each half itself; everything else eases the whole cycle.
        if animation.type != .pulse { group.timingFunction = timing(animation.easing) }
        group.duration = animation.duration
        for part in parts { part.duration = animation.duration }
        group.beginTime = start
        group.fillMode = .backwards
        group.repeatCount = animation.repeatCount.map(Float.init) ?? .infinity
        // The shimmer moves its mask; the rest move the layer.
        (mask ?? layer).add(group, forKey: key)
        return mask
    }
}
