import Testing
import FudehandCore

// Where a node and its descendants can paint (#241): the canvas leaves out top-level layers whose paint bounds miss the view,
// and draws a top-level frame's bitmap over them.

@Test func paintBoundsOfAPlainNodeIsItsRectangle() {
    let node = DesignNode(id: "a", type: .rectangle, x: 50, y: 60, width: 100, height: 40)
    #expect(node.paintBounds == Rect(x: 0, y: 0, width: 100, height: 40))
}

@Test func paintBoundsIncludeChildrenOutsideAFrameThatDoesNotClip() {
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    frame.clipsContent = false
    frame.children = [DesignNode(id: "c", type: .rectangle, x: -20, y: 90, width: 30, height: 40)]
    #expect(frame.paintBounds == Rect(x: -20, y: 0, width: 120, height: 130))
    frame.clipsContent = true
    #expect(frame.paintBounds == Rect(x: 0, y: 0, width: 100, height: 100))
}

@Test func hiddenChildrenAndEffectsPaintNothing() {
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    frame.clipsContent = false
    var child = DesignNode(id: "c", type: .rectangle, x: 200, y: 0, width: 10, height: 10)
    child.visible = false
    frame.children = [child]
    frame.effects = [DesignEffect(type: .dropShadow, visible: false, radius: 50)]
    #expect(frame.paintBounds == Rect(x: 0, y: 0, width: 100, height: 100))
}

@Test func shadowsAndLayerBlursGrowThePaintBounds() {
    var node = DesignNode(id: "a", type: .rectangle, width: 100, height: 100)
    node.effects = [DesignEffect(type: .dropShadow, x: 3, y: 4, radius: 10, spread: 2)]
    // A Gaussian with standard deviation radius / 2 fades out within 1.5 × radius; the reach rounds that up to 2 × radius.
    let shadow = 3.0 + 4 + 2 + 20
    #expect(node.paintBounds == Rect(x: -shadow, y: -shadow, width: 100 + 2 * shadow, height: 100 + 2 * shadow))
    node.effects = [DesignEffect(type: .layerBlur, radius: 10)]
    #expect(node.paintBounds == Rect(x: -20, y: -20, width: 140, height: 140))
    node.effects = [DesignEffect(type: .glass), DesignEffect(type: .innerShadow, radius: 30), DesignEffect(type: .noise)]
    #expect(node.paintBounds == Rect(x: 0, y: 0, width: 100, height: 100))
}

@Test func aChildsEffectsGrowItsAncestorsPaintBounds() {
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    frame.clipsContent = false
    var child = DesignNode(id: "c", type: .rectangle, x: 10, y: 10, width: 20, height: 20)
    child.effects = [DesignEffect(type: .layerBlur, radius: 10)]
    frame.children = [child]
    #expect(frame.paintBounds == Rect(x: -10, y: -10, width: 110, height: 110))
}

@Test func turnedLayersHaveNoPaintBounds() {
    var frame = DesignNode(id: "f", type: .frame, width: 100, height: 100)
    var child = DesignNode(id: "c", type: .rectangle, width: 20, height: 20)
    child.effects = [DesignEffect(type: .transform3D, rotateY: 20)]
    frame.children = [child]
    // A frame that clips keeps even a turned child inside it.
    #expect(frame.paintBounds == Rect(x: 0, y: 0, width: 100, height: 100))
    frame.clipsContent = false
    #expect(frame.paintBounds == nil)
    frame.children = []
    frame.effects = [DesignEffect(type: .perspective)]
    #expect(frame.paintBounds == nil)
}
