import Foundation
import Testing
import FudehandCore

private func decode(_ json: String) throws -> DesignDocument { try DesignDocument.decode(Data(json.utf8)) }

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func node(_ json: String) throws -> DesignNode { try DesignJSON.node(from: try JSONSerialization.jsonObject(with: Data(json.utf8))) }

private func animation(_ json: String) throws -> LayerAnimation? {
    try node(#"{"id":"a","type":"rectangle","animation":"# + json + "}").animation
}

private func text(_ id: String, _ content: String, sequence: String? = nil) -> String {
    let extra = sequence.map { #","sequence":"# + $0 } ?? ""
    return #"{"id":""# + id + #"","type":"text","text":{"content":""# + content + #"""# + extra + "}}"
}

@Test func animationsGetTheDefaultsOfTheirType() throws {
    #expect(try animation(#"{"type":"fade-in"}"#) == LayerAnimation(type: .fadeIn))
    let fade = LayerAnimation(type: .fadeIn)
    #expect(fade.duration == 0.3 && fade.delay == 0 && fade.easing == .easeOut && fade.repeatCount == 1)
    let spin = LayerAnimation(type: .spin)
    #expect(spin.duration == 1 && spin.easing == .linear && spin.repeatCount == nil)
    let pulse = LayerAnimation(type: .pulse)
    #expect(pulse.easing == .easeInOut && pulse.property == .scale && pulse.repeatCount == nil)
    #expect(LayerAnimation(type: .shimmer).duration == 1.5)
    let slide = LayerAnimation(type: .slideIn)
    #expect(slide.from == .bottom && slide.distance == 40)
    #expect(AnimationType.allCases.filter(\.isEntrance) == [.fadeIn, .slideIn, .scaleIn])
}

@Test func readsAndWritesAnimations() throws {
    let slide = try #require(try animation(#"{"type":"slide-in","from":"left","distance":120,"duration":0.5,"delay":0.2,"easing":"linear","repeat":3}"#))
    #expect(slide.from == .left && slide.distance == 120 && slide.duration == 0.5 && slide.delay == 0.2 && slide.easing == .linear && slide.repeatCount == 3)
    let pulse = try #require(try animation(#"{"type":"pulse","property":"opacity","repeat":"infinite"}"#))
    #expect(pulse.property == .opacity && pulse.repeatCount == nil)

    var layer = DesignNode(id: "a", type: .rectangle)
    layer.animation = slide
    let written = try #require(DesignJSON.object(layer, includeImageData: true)["animation"] as? [String: Any])
    #expect(written["type"] as? String == "slide-in" && written["from"] as? String == "left" && written["distance"] as? Double == 120)
    #expect(written["repeat"] as? Int == 3 && written["property"] == nil)
    layer.animation = pulse
    let loop = try #require(DesignJSON.object(layer, includeImageData: true)["animation"] as? [String: Any])
    #expect(loop["repeat"] as? String == "infinite" && loop["property"] as? String == "opacity" && loop["from"] == nil)
    // Written fields read back to the same animation.
    #expect(try DesignJSON.node(from: DesignJSON.object(layer, includeImageData: true)).animation == pulse)
}

@Test func validatesAnimationFields() {
    func failure(_ json: String) -> String? { message { _ = try animation(json) } }
    #expect(failure(#"{}"#) == "Layer a: missing animation.type")
    #expect(failure(#"{"type":"bounce"}"#)
            == "Layer a: animation.type must be one of fade-in, slide-in, scale-in, spin, pulse, shimmer; got bounce")
    #expect(failure(#"{"type":"fade-in","from":"left"}"#) == "Layer a: unsupported field animation.from")
    #expect(failure(#"{"type":"spin","property":"scale"}"#) == "Layer a: unsupported field animation.property")
    #expect(failure(#"{"type":"slide-in","from":"center"}"#) == "Layer a: animation.from must be one of left, right, top, bottom; got center")
    #expect(failure(#"{"type":"pulse","property":"color"}"#) == "Layer a: animation.property must be one of scale, opacity; got color")
    #expect(failure(#"{"type":"spin","duration":0}"#) == "Layer a: animation.duration must be greater than 0")
    #expect(failure(#"{"type":"spin","duration":61}"#) == "Layer a: animation.duration must not be greater than 60")
    #expect(failure(#"{"type":"spin","delay":-1}"#) == "Layer a: animation.delay must not be negative")
    #expect(failure(#"{"type":"spin","repeat":0}"#) == "Layer a: animation.repeat must be an integer from 1 to 1000 or \"infinite\"")
    #expect(failure(#"{"type":"spin","repeat":1.5}"#) == "Layer a: animation.repeat must be an integer from 1 to 1000 or \"infinite\"")
    #expect(failure(#"{"type":"spin","repeat":"forever"}"#) == "Layer a: animation.repeat must be an integer from 1 to 1000 or \"infinite\"")
    #expect(failure(#"{"type":"spin","trigger":"click"}"#) == "Layer a: unsupported field animation.trigger")
    #expect(failure(#""spin""#) == "Layer a: animation must be an object")
}

@Test func anUpdateReplacesTheWholeAnimation() throws {
    var layer = try node(#"{"id":"a","type":"rectangle","animation":{"type":"slide-in","from":"left"}}"#)
    try DesignJSON.apply(["animation": ["type": "spin"]], to: &layer)
    #expect(layer.animation == LayerAnimation(type: .spin))
    try DesignJSON.apply(["animation": NSNull()], to: &layer)
    #expect(layer.animation == nil)
}

@Test func readsWritesAndValidatesTextSequences() throws {
    let layer = try node(text("t", "60", sequence: #"{"items":["3","2","1"],"interval":0.5,"loop":true}"#))
    #expect(layer.text?.sequence == TextSequence(items: ["3", "2", "1"], interval: 0.5, loop: true))
    #expect(try node(text("t", "", sequence: #"{"items":["a"]}"#)).text?.sequence == TextSequence(items: ["a"], interval: 1, loop: false))
    let written = try #require((DesignJSON.object(layer, includeImageData: true)["text"] as? [String: Any])?["sequence"] as? [String: Any])
    #expect(written["items"] as? [String] == ["3", "2", "1"] && written["interval"] as? Double == 0.5 && written["loop"] as? Bool == true)

    func failure(_ sequence: String) -> String? { message { _ = try node(text("t", "", sequence: sequence)) } }
    #expect(failure(#"{"items":[]}"#) == "Layer t: text.sequence.items must hold 1 to 1000 strings")
    #expect(failure(#"{"items":[1,2]}"#) == "Layer t: text.sequence.items must hold 1 to 1000 strings")
    #expect(failure(#"{}"#) == "Layer t: missing text.sequence.items")
    #expect(failure(#"{"items":["a"],"interval":0}"#) == "Layer t: text.sequence.interval must not be less than 0.05")
    #expect(failure(#"{"items":["a"],"every":1}"#) == "Layer t: unsupported field text.sequence.every")
}

@Test func aTextPatchReplacesTheWholeSequenceAndKeepsTheStyle() throws {
    var layer = try node(#"{"id":"t","type":"text","text":{"content":"60","fontSize":24,"sequence":{"items":["3","2"],"loop":true}}}"#)
    try DesignJSON.apply(["text": ["sequence": ["items": ["9"]]]], to: &layer)
    #expect(layer.text?.sequence == TextSequence(items: ["9"]))
    #expect(layer.text?.fontSize == 24 && layer.text?.content == "60")
    try DesignJSON.apply(["text": ["sequence": NSNull()]], to: &layer)
    #expect(layer.text?.sequence == nil)
}

@Test func versionTwoFilesOpenAndNewerOnesAreRefused() throws {
    let old = try decode(#"{"format":"fudehand.design","version":2,"nodes":[{"id":"a","type":"frame"}]}"#)
    #expect(old.nodes[0].animation == nil)
    #expect(DesignDocument.formatVersion == 4)
    #expect(message { _ = try decode(#"{"format":"fudehand.design","version":5,"nodes":[]}"#) }
            == "File was created by a newer version of Fudehand (format version 5); upgrade Fudehand to open it")
}

@Test func aSequenceStepsAtItsIntervalAndLoopsOrStops() {
    let stop = TextSequence(items: ["3", "2", "1"], interval: 1, loop: false)
    #expect([-1, 0, 0.99, 1, 2.5, 3, 100].map { stop.index(at: $0) } == [0, 0, 0, 1, 2, 2, 2])
    #expect(stop.nextChange(after: 0) == 1)
    #expect(stop.nextChange(after: 1.2) == 2)
    #expect(stop.nextChange(after: 2) == nil)
    let loop = TextSequence(items: ["a", "b"], interval: 0.5, loop: true)
    #expect([0, 0.5, 1, 1.6].map { loop.index(at: $0) } == [0, 1, 0, 1])
    #expect(loop.nextChange(after: 1.6) == 2)
    #expect(TextSequence(items: ["only"], interval: 1, loop: true).nextChange(after: 0) == nil)
}

@Test func playbackShowsTheCurrentItemsAndRelaysTheFrame() throws {
    var frame = try node(#"{"id":"f","type":"frame","width":200,"height":100,"layout":{"direction":"horizontal","spacing":10},"children":["#
        + text("count", "60", sequence: #"{"items":["10","9"],"interval":1}"#) + "," + text("unit", "s") + "]}")
    // A fixed measure: 10 pt per character.
    let measure: TextMeasure = { text, _ in Size(width: Double(text.content.count * 10), height: 20) }
    var nodes = [frame]
    DesignLayout.apply(to: &nodes, measure: measure)
    frame = nodes[0]
    #expect(frame.children[1].x == 30)

    let first = TextSequence.playing(frame, at: 0, measure: measure)
    #expect(first.children[0].text?.content == "10" && first.children[1].x == 30)
    let second = TextSequence.playing(frame, at: 1, measure: measure)
    #expect(second.children[0].text?.content == "9" && second.children[0].width == 10 && second.children[1].x == 20)
    #expect(TextSequence.nextChange(in: frame, after: 0) == 1)
    #expect(TextSequence.nextChange(in: frame, after: 1) == nil)
    // The style is kept; only the content changes.
    #expect(second.children[0].text?.sequence == frame.children[0].text?.sequence)
}

@Test func onlyVisibleLayersAnimate() throws {
    let frame = try node(#"{"id":"f","type":"frame","animation":{"type":"fade-in"},"children":[{"id":"a","type":"rectangle","animation":{"type":"spin"}},{"id":"g","type":"group","visible":false,"children":[{"id":"b","type":"rectangle","animation":{"type":"pulse"}}]},"#
        + text("t", "", sequence: #"{"items":["x","y"]}"#) + "]}")
    #expect(LayerAnimation.animated(in: frame).map(\.id) == ["f", "a"])
    #expect(TextSequence.hasSequences(in: frame))
    var hidden = frame
    hidden.children[2].visible = false
    #expect(!TextSequence.hasSequences(in: hidden))
}
