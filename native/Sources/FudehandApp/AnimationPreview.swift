import AppKit
import FudehandCore
import SwiftUI

/// The properties panel's animation preview: the selected layer and its children, scaled down to fit when larger than the box,
/// playing their animations and text sequences without playing the prototype. The editing canvas is not touched.
struct AnimationPreview: View {
    let node: DesignNode
    @State private var replay = 0

    static let size = CGSize(width: 260, height: 180)

    var body: some View {
        VStack(spacing: 10) {
            AnimationPreviewStage(node: node, replay: replay)
                .frame(width: Self.size.width, height: Self.size.height)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Button(L("Replay")) { replay += 1 }
        }
        .padding(12)
    }
}

private struct AnimationPreviewStage: NSViewRepresentable {
    let node: DesignNode
    let replay: Int

    func makeNSView(context: Context) -> AnimationPreviewView { AnimationPreviewView(frame: CGRect(origin: .zero, size: AnimationPreview.size)) }

    func updateNSView(_ view: AnimationPreviewView, context: Context) { view.show(node, replay: replay) }
}

final class AnimationPreviewView: NSView {
    private let content = CALayer()
    private let renderer = DesignRenderer()
    private lazy var player = LayerAnimationPlayer(renderer: renderer)
    private var shown: (node: DesignNode, replay: Int)?
    private var placed = DesignNode(id: "", type: .rectangle)
    private var scale: CGFloat = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Layer blurs and background blurs are Core Image filters on the design's layers.
        layerUsesCoreImageFilters = true
        content.anchorPoint = .zero
        content.actions = DesignRenderer.noActions
        content.addSublayer(renderer.root)
        layer?.addSublayer(content)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("Animation preview"))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() { renderer.contentsScale = (window?.backingScaleFactor ?? 2) * scale }

    /// Plays `node` from the start whenever it changes or Replay is pressed.
    func show(_ node: DesignNode, replay: Int) {
        guard shown?.node != node || shown?.replay != replay else { return }
        shown = (node, replay)
        placed = node
        placed.x = 0
        placed.y = 0
        placed.visible = true
        let box = AnimationPreview.size, inset: CGFloat = 16
        scale = min(1, (box.width - 2 * inset) / max(node.width, 1), (box.height - 2 * inset) / max(node.height, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        content.position = CGPoint(x: (box.width - node.width * scale) / 2, y: (box.height - node.height * scale) / 2)
        CATransaction.commit()
        renderer.contentsScale = (window?.backingScaleFactor ?? 2) * scale
        player.stop()
        renderer.sync([placed])
        player.redraw = { [weak self] in self.map { $0.renderer.sync([$0.player.playing($0.placed)]) } }
        player.start(placed)
        if TextSequence.hasSequences(in: placed) { player.redraw() }
    }
}
