import AppKit
import FudehandCore
import SwiftUI

/// What the prototype window plays. Each Play Prototype gets a new token, so playing again restarts even from the same frame.
struct PrototypeRequest: Equatable {
    let start: String
    let token: Int
}

/// The prototype window: plays the design document's top-level frames at their actual size (scaled down only when the screen
/// is smaller). Clicks trigger interactions instead of selecting layers, and the editing canvas is not affected. It follows
/// the document as it is edited, by people or the Agent.
struct PrototypeWindow: View {
    @ObservedObject var store: FudehandStore
    @ObservedObject private var shown: PrototypeShown

    init(store: FudehandStore) {
        self.store = store
        shown = store.prototypeShown
    }

    var body: some View {
        let frame = shown.frame.flatMap { Prototype.frame($0, in: store.document) }
        let scale = frame.map { Self.fitScale(Size(width: $0.width, height: $0.height)) } ?? 1
        // The stage stays in place while its frame is missing, so undoing the deletion resumes playback where it was.
        ZStack {
            if let request = store.prototypeRequest {
                PrototypeStage(document: store.document, request: request, scale: scale) { store.prototypeMoved(to: $0) }
            }
            if frame == nil {
                VStack(spacing: 12) {
                    Text(store.prototypeRequest == nil ? L("Choose Canvas › Play Prototype to play the design document.") : L("This frame was deleted."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if store.prototypeStart != nil { Button(L("Play from the Start")) { store.playPrototype() } }
                }
                .padding(24)
            }
        }
        .frame(width: frame.map { $0.width * scale } ?? 360, height: frame.map { $0.height * scale } ?? 220)
        .navigationTitle(frame?.name ?? L("Prototype"))
        .onAppear { store.prototypeWindowOpen = true }
        .onDisappear { store.prototypeWindowOpen = false }
    }

    /// Frames larger than the screen are scaled down to fit it; smaller ones are shown at their actual size.
    static func fitScale(_ size: Size, screen: CGSize? = NSScreen.main?.visibleFrame.size) -> CGFloat {
        guard let screen, size.width > 0, size.height > 0 else { return 1 }
        // Leaves room for the title bar.
        return min(1, screen.width / size.width, (screen.height - 32) / size.height)
    }
}

struct PrototypeStage: NSViewRepresentable {
    let document: DesignDocument
    let request: PrototypeRequest
    let scale: CGFloat
    let moved: (String) -> Void

    func makeNSView(context: Context) -> PrototypeStageView {
        let view = PrototypeStageView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PrototypeStageView, context: Context) {
        view.moved = moved
        view.scale = scale
        view.show(document, request: request)
    }
}

/// Renders the frame on show with its open overlays and plays transitions. Two renderers take turns: during a transition one
/// shows the frame being left and the other the frame arriving, which may be the same frame. Scrolling, layer states, and
/// visibility toggles only change what is rendered; the design document is never touched.
final class PrototypeStageView: NSView {
    var moved: (String) -> Void = { _ in }
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { content.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale)); rasterize() } }
    }
    private let content = CALayer()
    private var shown = DesignRenderer()
    private var spare = DesignRenderer()
    /// Each renderer's layer animations and text sequences, restarted whenever it brings a frame in.
    private var players: [ObjectIdentifier: LayerAnimationPlayer] = [:]
    private var player: PrototypePlayer?
    private var token: Int?
    private var document = DesignDocument()
    /// The layer answering a click under the pointer when the button went down; a click fires only when it comes up over the same layer.
    private var pressedResponder: String?
    /// The layer showing states under the pointer when the button went down.
    private var pressedStyled: String?
    /// The button went down outside the topmost overlay.
    private var pressedOutside = false
    /// The layers drawn in their hover and pressed states.
    private var hovered: String?
    private var pressed: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        content.anchorPoint = .zero
        content.actions = DesignRenderer.noActions
        content.addSublayer(shown.root)
        layer?.addSublayer(content)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func accessibilityLabel() -> String? { L("Prototype") }

    override func viewDidMoveToWindow() {
        // Closing the window stops the loops and sequence timers; showing it again starts the frame's animations anew.
        if window == nil { players.values.forEach { $0.stop() } } else if let player { bringIn(shown, player.current, after: 0) }
        window?.makeFirstResponder(self)
        rasterize()
    }

    override func viewDidChangeBackingProperties() { rasterize() }

    func show(_ next: DesignDocument, request: PrototypeRequest) {
        document = next
        if token != request.token {
            token = request.token
            player = PrototypePlayer(start: request.start)
            // Should SwiftUI build a new stage for the last playback, it starts that playback over; reported after this view update.
            DispatchQueue.main.async { [moved] in moved(request.start) }
            hovered = nil
            pressed = nil
            spare.root.removeFromSuperlayer()
            animations(spare).stop()
            shown.root.removeAllAnimations()
            if let player { bringIn(shown, player.current, after: 0) }
        }
        // Edits re-render the frame without restarting its animations; text sequences follow them.
        if let player {
            render(shown)
            if let frame = Prototype.frame(player.current, in: document) { animations(shown).update(frame) }
        }
    }

    private func animations(_ renderer: DesignRenderer) -> LayerAnimationPlayer {
        if let existing = players[ObjectIdentifier(renderer)] { return existing }
        let created = LayerAnimationPlayer(renderer: renderer)
        players[ObjectIdentifier(renderer)] = created
        return created
    }

    /// Shows frame `id` in `renderer` and starts its animations from the beginning; they begin after `wait` seconds, when the
    /// transition bringing the frame in has finished.
    private func bringIn(_ renderer: DesignRenderer, _ id: String, after wait: Double) {
        let player = animations(renderer)
        // Stopping would otherwise redraw the frame this renderer showed before.
        player.redraw = {}
        player.stop()
        render(renderer)
        // Only the renderer on show follows its sequences; the one being left keeps its last look until it is removed.
        player.redraw = { [weak self, unowned renderer] in
            guard let self, self.shown === renderer else { return }
            self.render(renderer)
        }
        guard let frame = Prototype.frame(id, in: document) else { return }
        player.start(frame, after: wait)
        // Sequences show their first item from the start.
        if TextSequence.hasSequences(in: frame) { render(renderer) }
    }

    private func rasterize() {
        let value = (window?.backingScaleFactor ?? 2) * scale
        shown.contentsScale = value
        spare.contentsScale = value
    }

    private func render(_ renderer: DesignRenderer) {
        guard let player else { renderer.sync([]); return }
        var styles: [String: LayerStyle] = [:]
        for id in Set([hovered, pressed].compactMap { $0 }) {
            if let node = document.node(id), let style = Prototype.style(of: node, hovered: id == hovered || id == pressed, pressed: id == pressed) {
                styles[id] = style
            }
        }
        var scene = player.scene(in: document, styles: styles)
        // The frame on show runs its text sequences; overlays show their layers as designed.
        if !scene.isEmpty { scene[0] = animations(renderer).playing(scene[0]) }
        renderer.sync(scene)
    }

    private func stagePoint(_ event: NSEvent) -> Point {
        let point = convert(event.locationInWindow, from: nil)
        return Point(x: point.x / scale, y: point.y / scale)
    }

    private func target(_ event: NSEvent) -> PrototypePlayer.Target {
        player?.target(at: stagePoint(event), in: document) ?? PrototypePlayer.Target()
    }

    /// Draws the layers now in a state, easing those that enter or leave one from how they look now.
    private func setStates(hovered nextHovered: String?, pressed nextPressed: String?) {
        guard nextHovered != hovered || nextPressed != pressed else { return }
        let changed = Set([hovered, pressed, nextHovered, nextPressed].compactMap { $0 })
        var before: [String: (CGColor?, CGColor?, Float)] = [:]
        for id in changed {
            guard let layer = shown.layer(for: id) else { continue }
            let now = layer.presentation() ?? layer
            before[id] = (now.backgroundColor, (now as? CAShapeLayer)?.fillColor, now.opacity)
        }
        hovered = nextHovered
        pressed = nextPressed
        render(shown)
        for (id, (background, fill, opacity)) in before {
            guard let layer = shown.layer(for: id) else { continue }
            func ease(_ key: String, from: Any?, to: Any?) {
                guard let from, !CFEqual(from as CFTypeRef, (to ?? NSNull()) as CFTypeRef) else { return }
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = LayerStates.transitionDuration
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "state.\(key)")
            }
            if let shape = layer as? CAShapeLayer { ease("fillColor", from: fill, to: shape.fillColor) }
            else { ease("backgroundColor", from: background, to: layer.backgroundColor) }
            ease("opacity", from: opacity, to: layer.opacity)
        }
    }

    private func updateHover(_ event: NSEvent) {
        let target = target(event)
        (target.responder == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        setStates(hovered: target.styled, pressed: pressedStyled != nil && target.styled == pressedStyled ? pressedStyled : nil)
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) { setStates(hovered: nil, pressed: nil) }

    override func mouseDown(with event: NSEvent) {
        let target = target(event)
        pressedResponder = target.responder?.node.id
        pressedStyled = target.styled
        pressedOutside = target.outside
        setStates(hovered: target.styled, pressed: target.styled)
    }

    /// The pressed state shows only while the pointer stays over the pressed layer.
    override func mouseDragged(with event: NSEvent) { updateHover(event) }

    override func mouseUp(with event: NSEvent) {
        let released = target(event)
        // A click fires on the layer it was pressed on, or outside the topmost overlay when it was pressed outside it too.
        let fires = (pressedResponder != nil && pressedResponder == released.responder?.node.id) || (pressedOutside && released.outside)
        pressedResponder = nil
        pressedStyled = nil
        pressedOutside = false
        if fires, var player, let effect = player.click(at: stagePoint(event), in: document) {
            self.player = player
            perform(effect)
        }
        updateHover(event)
    }

    /// Trackpad and wheel scrolling move the scrolling frame under the pointer; the trackpad's own momentum carries on after a flick.
    override func scrollWheel(with event: NSEvent) {
        guard var player else { return }
        let delta = CanvasGeometry.wheelDelta(Point(x: event.scrollingDeltaX, y: event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
        // Content follows the fingers: moving them up scrolls further into it.
        guard player.scroll(by: Point(x: -delta.x / scale, y: -delta.y / scale), at: stagePoint(event), wheel: !event.hasPreciseScrollingDeltas,
                            in: document) else { return }
        self.player = player
        render(shown)
        updateHover(event)
    }

    /// Esc closes the window and returns to editing.
    override func cancelOperation(_ sender: Any?) { window?.performClose(sender) }

    private func perform(_ effect: PrototypePlayer.Effect) {
        switch effect {
        case .move(let step):
            hovered = nil
            pressed = nil
            play(step)
        case .toggle:
            render(shown)
        case .openOverlay(let overlay):
            render(shown)
            animate(overlay, opening: true)
        case .closeOverlay(let overlay):
            // While it animates, the player keeps the overlay in the scene, so renders in the meantime (hover, scrolling) keep it.
            if player?.isTransitioning == true { animate(overlay, opening: false) } else { render(shown) }
        }
    }

    /// Plays an overlay's transition: the overlay comes in from (or leaves towards) the edge its transition names, or fades, and
    /// its scrim fades. When it has finished closing, the scene is rendered without it.
    private func animate(_ overlay: PrototypeOverlay, opening: Bool) {
        guard player?.isTransitioning == true else { return }
        guard let layer = shown.layer(for: overlay.frame), let stage = player.flatMap({ Prototype.frame($0.current, in: document) }) else {
            player?.finishTransition()
            render(shown)
            return
        }
        let transition = overlay.transition
        let renderer = shown
        let session = token
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.token == session else { return }
            renderer.layer(for: overlay.frame)?.removeAllAnimations()
            renderer.layer(for: Prototype.scrimID(overlay.frame))?.removeAllAnimations()
            self.player?.finishTransition()
            // Finishing drops the closing overlay from the scene.
            if !opening { self.render(renderer) }
        }
        func animate(_ target: CALayer, _ key: String, hidden: Any, visible: Any) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = opening ? hidden : visible
            animation.toValue = opening ? visible : hidden
            animation.duration = transition.duration
            animation.timingFunction = CAMediaTimingFunction(name: Self.timing(transition.easing))
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            target.add(animation, forKey: "overlay.\(key)")
        }
        if let scrim = shown.layer(for: Prototype.scrimID(overlay.frame)) { animate(scrim, "opacity", hidden: 0, visible: 1) }
        // Layers are positioned by their center; "away" places the overlay just past the edge it comes in from.
        let place = layer.position
        let half = CGSize(width: layer.bounds.width / 2, height: layer.bounds.height / 2)
        let away: CGPoint? = switch transition.type {
        case .sheet, .pushUp: CGPoint(x: place.x, y: stage.height + half.height)
        case .pushDown: CGPoint(x: place.x, y: -half.height)
        case .pushLeft: CGPoint(x: stage.width + half.width, y: place.y)
        case .pushRight: CGPoint(x: -half.width, y: place.y)
        case .none, .dissolve: nil
        }
        if let away { animate(layer, "position", hidden: NSValue(point: away), visible: NSValue(point: place)) }
        else { animate(layer, "opacity", hidden: 0, visible: 1) }
        CATransaction.commit()
    }

    private func play(_ step: PrototypePlayer.Step) {
        let leaving = shown, arriving = spare
        shown = arriving
        spare = leaving
        arriving.root.removeAllAnimations()
        arriving.root.opacity = 1
        let transition = step.transition
        bringIn(arriving, step.to, after: player?.isTransitioning == true ? transition.duration : 0)
        // A reversed dissolve or sheet takes the frame being left away from on top of the frame arriving.
        let leavingOnTop = step.reversed && (transition.type == .dissolve || transition.type == .sheet)
        if leavingOnTop { content.insertSublayer(arriving.root, below: leaving.root) } else { content.addSublayer(arriving.root) }
        moved(step.to)
        guard player?.isTransitioning == true else { leaving.root.removeFromSuperlayer(); animations(leaving).stop(); return }

        let size = [step.from, step.to].compactMap { Prototype.frame($0, in: document) }
            .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
        CATransaction.begin()
        // A restart during the transition starts a new playback; this one's completion must then leave it alone.
        let session = token
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.token == session else { return }
            leaving.root.removeAllAnimations()
            arriving.root.removeAllAnimations()
            if self.shown !== leaving { leaving.root.removeFromSuperlayer(); self.animations(leaving).stop() }
            self.player?.finishTransition()
        }
        let timing = CAMediaTimingFunction(name: Self.timing(transition.easing))
        func animate(_ layer: CALayer, _ key: String, from: Any, to: Any) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = transition.duration
            animation.timingFunction = timing
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "prototype.\(key)")
        }
        func offset(_ x: CGFloat, _ y: CGFloat) -> NSValue { NSValue(point: CGPoint(x: x * size.width, y: y * size.height)) }
        let still = offset(0, 0)
        switch transition.type {
        case .none: break
        case .dissolve:
            if step.reversed { animate(leaving.root, "opacity", from: 1, to: 0) } else { animate(arriving.root, "opacity", from: 0, to: 1) }
        case .sheet:
            if step.reversed { animate(leaving.root, "position", from: still, to: offset(0, 1)) }
            else { animate(arriving.root, "position", from: offset(0, 1), to: still) }
        case .pushLeft, .pushRight, .pushUp, .pushDown:
            // The direction the content travels; going back sends it the other way.
            var (dx, dy): (CGFloat, CGFloat) = switch transition.type {
            case .pushLeft: (-1, 0)
            case .pushRight: (1, 0)
            case .pushUp: (0, -1)
            default: (0, 1)
            }
            if step.reversed { dx = -dx; dy = -dy }
            animate(arriving.root, "position", from: offset(-dx, -dy), to: still)
            animate(leaving.root, "position", from: still, to: offset(dx, dy))
        }
        CATransaction.commit()
    }

    static func timing(_ easing: TransitionEasing) -> CAMediaTimingFunctionName {
        switch easing {
        case .linear: return .linear
        case .easeIn: return .easeIn
        case .easeOut: return .easeOut
        case .easeInOut: return .easeInEaseOut
        }
    }
}
