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
    /// The frame on show, as reported by the stage; nil until the first move after a request.
    @State private var current: String?

    var body: some View {
        let shown = store.prototypeRequest.map { current ?? $0.start }
        let frame = shown.flatMap { Prototype.frame($0, in: store.document) }
        let scale = frame.map { Self.fitScale(Size(width: $0.width, height: $0.height)) } ?? 1
        // The stage stays in place while its frame is missing, so undoing the deletion resumes playback where it was.
        ZStack {
            if let request = store.prototypeRequest {
                PrototypeStage(document: store.document, request: request, scale: scale) { current = $0 }
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
        .onChange(of: store.prototypeRequest) { _, _ in current = nil }
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

/// Renders the frame on show and plays transitions. Two renderers take turns: during a transition one shows the frame being
/// left and the other the frame arriving, which may be the same frame.
final class PrototypeStageView: NSView {
    var moved: (String) -> Void = { _ in }
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { content.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale)); rasterize() } }
    }
    private let content = CALayer()
    private var shown = DesignRenderer()
    private var spare = DesignRenderer()
    private var player: PrototypePlayer?
    private var token: Int?
    private var document = DesignDocument()

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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func accessibilityLabel() -> String? { L("Prototype") }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        rasterize()
    }

    override func viewDidChangeBackingProperties() { rasterize() }

    func show(_ next: DesignDocument, request: PrototypeRequest) {
        document = next
        if token != request.token {
            token = request.token
            player = PrototypePlayer(start: request.start)
            spare.root.removeFromSuperlayer()
            shown.root.removeAllAnimations()
        }
        if let player { render(shown, player.current) }
    }

    private func rasterize() {
        let value = (window?.backingScaleFactor ?? 2) * scale
        shown.contentsScale = value
        spare.contentsScale = value
    }

    private func render(_ renderer: DesignRenderer, _ id: String) {
        guard var frame = Prototype.frame(id, in: document) else { renderer.sync([]); return }
        frame.x = 0
        frame.y = 0
        frame.visible = true
        renderer.sync([frame])
    }

    private func framePoint(_ event: NSEvent) -> Point {
        let point = convert(event.locationInWindow, from: nil)
        return Point(x: point.x / scale, y: point.y / scale)
    }

    override func mouseMoved(with event: NSEvent) {
        let frame = player.flatMap { Prototype.frame($0.current, in: document) }
        let target = frame.flatMap { Prototype.responder(in: $0, at: framePoint(event)) }
        (target == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard var player, let step = player.click(at: framePoint(event), in: document) else { return }
        self.player = player
        play(step)
    }

    /// Esc closes the window and returns to editing.
    override func cancelOperation(_ sender: Any?) { window?.performClose(sender) }

    private func play(_ step: PrototypePlayer.Step) {
        let leaving = shown, arriving = spare
        shown = arriving
        spare = leaving
        arriving.root.removeAllAnimations()
        arriving.root.opacity = 1
        render(arriving, step.to)
        let transition = step.transition
        // A reversed dissolve or sheet takes the frame being left away from on top of the frame arriving.
        let leavingOnTop = step.reversed && (transition.type == .dissolve || transition.type == .sheet)
        if leavingOnTop { content.insertSublayer(arriving.root, below: leaving.root) } else { content.addSublayer(arriving.root) }
        moved(step.to)
        guard player?.isTransitioning == true else { leaving.root.removeFromSuperlayer(); return }

        let size = [step.from, step.to].compactMap { Prototype.frame($0, in: document) }
            .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            leaving.root.removeAllAnimations()
            arriving.root.removeAllAnimations()
            if self?.shown !== leaving { leaving.root.removeFromSuperlayer() }
            self?.player?.finishTransition()
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
