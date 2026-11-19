import Foundation
import Testing
import FudehandCore

/// In-screen interactions (#150): scrolling, hover and pressed states, overlays, and visibility toggles.

private func decode(_ json: String) throws -> DesignDocument { try DesignDocument.decode(Data(json.utf8)) }

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func node(_ json: String) throws -> DesignNode { try DesignJSON.node(from: try JSONSerialization.jsonObject(with: Data(json.utf8))) }

/// Feed scrolls vertically under a fixed header, with a card that has hover and pressed states and opens Menu below itself, a
/// button that opens Dialog centered over a scrim, a tab that toggles two panels, and a horizontal carousel inside the content.
/// Menu has a close button and an item that navigates to Detail; Dialog cannot be closed by clicking outside it.
private let gray = DesignColor(r: 0xEE / 255.0, g: 0xEE / 255.0, b: 0xEE / 255.0)
private let dim = DesignColor(r: 0, g: 0, b: 0, a: 0x80 / 255.0)

private let screens = """
{"format":"fudehand.design","version":3,"nodes":[
  {"id":"feed","type":"frame","width":400,"height":600,"scroll":"vertical","children":[
    {"id":"list","type":"frame","x":0,"y":0,"width":400,"height":1500,"children":[
      {"id":"card","type":"rectangle","x":20,"y":100,"width":100,"height":50,"fill":"#FFFFFF",
       "states":{"hover":{"fill":"#EEEEEE"},"pressed":{"opacity":0.5}},
       "interaction":{"action":"open-overlay","destination":"menu","position":"below-trigger"}},
      {"id":"open-dialog","type":"rectangle","x":20,"y":200,"width":100,"height":50,
       "interaction":{"action":"open-overlay","destination":"dialog","background":"#00000080","closeOnOutsideClick":false,
                      "transition":{"type":"dissolve","duration":0.2}}},
      {"id":"tab","type":"rectangle","x":20,"y":300,"width":100,"height":50,
       "interaction":{"action":"toggle-visibility","targets":["panel-a","panel-b"]}},
      {"id":"panel-a","type":"rectangle","x":200,"y":300,"width":100,"height":50},
      {"id":"panel-b","type":"rectangle","x":200,"y":300,"width":100,"height":50,"visible":false},
      {"id":"carousel","type":"frame","x":0,"y":400,"width":400,"height":100,"scroll":"horizontal","children":[
        {"id":"slide","type":"rectangle","x":0,"y":0,"width":1000,"height":100}]}
    ]},
    {"id":"header","type":"rectangle","x":0,"y":0,"width":400,"height":60,"fixedOnScroll":true,
     "interaction":{"action":"back"}}
  ]},
  {"id":"menu","type":"frame","x":500,"width":200,"height":100,"children":[
    {"id":"close","type":"rectangle","x":0,"y":0,"width":50,"height":50,"interaction":{"action":"close-overlay"}},
    {"id":"go","type":"rectangle","x":100,"y":0,"width":50,"height":50,"interaction":{"action":"navigate","destination":"detail"}}
  ]},
  {"id":"dialog","type":"frame","x":800,"width":200,"height":200},
  {"id":"detail","type":"frame","x":1100,"width":400,"height":600}
]}
"""

// MARK: Reading and writing

@Test func readsAndWritesInScreenFields() throws {
    let document = try decode(screens)
    let feed = document.nodes[0]
    #expect(feed.scroll == .vertical && feed.children[1].fixedOnScroll)
    let card = feed.children[0].children[0]
    #expect(card.states == LayerStates(hover: LayerStyle(fill: gray), pressed: LayerStyle(opacity: 0.5)))
    #expect(card.interaction == .openOverlay(destination: "menu", overlay: OverlaySettings(position: .belowTrigger), transition: PrototypeTransition()))
    #expect(feed.children[0].children[1].interaction == .openOverlay(
        destination: "dialog", overlay: OverlaySettings(position: .center, background: dim, closeOnOutsideClick: false),
        transition: PrototypeTransition(type: .dissolve, duration: 0.2)))
    #expect(feed.children[0].children[2].interaction == .toggleVisibility(targets: ["panel-a", "panel-b"]))
    #expect(document.nodes[1].children[0].interaction == .closeOverlay)
    #expect(try DesignDocument.decode(try document.encoded()) == document)
    // Defaults are left out when written.
    let written = DesignJSON.object(document.nodes[1], includeImageData: false)
    #expect(written["scroll"] == nil && written["fixedOnScroll"] == nil && written["states"] == nil)
}

@Test func validatesInScreenFields() {
    func failure(_ fields: String, type: String = "rectangle") -> String? {
        message { _ = try node("{\"id\":\"a\",\"type\":\"\(type)\"," + fields + "}") }
    }
    #expect(failure(#""scroll":"vertical""#) == "Layer a: rectangle does not support scroll")
    #expect(failure(#""scroll":"both""#, type: "frame") == "Layer a: scroll must be one of none, vertical, horizontal; got both")
    #expect(failure(#""fixedOnScroll":1"#) == "Layer a: fixedOnScroll must be true or false")
    #expect(failure(#""states":{"focus":{}}"#) == "Layer a: unsupported field states.focus")
    #expect(failure(##""states":{"hover":{"stroke":"#000000"}}"##) == "Layer a: unsupported field states.hover.stroke")
    #expect(failure(#""states":{"pressed":{"opacity":2}}"#) == "Layer a: states.pressed.opacity must not be greater than 1")
    #expect(failure(#""states":{"hover":{"fill":"red"}}"#) == "Layer a: states.hover.fill Color must be #RRGGBB or #RRGGBBAA: red")
    #expect(failure(#""interaction":{"action":"open-overlay"}"#) == "Layer a: missing interaction.destination")
    #expect(failure(#""interaction":{"action":"open-overlay","destination":"m","position":"top"}"#)
            == "Layer a: interaction.position must be one of center, bottom, below-trigger; got top")
    #expect(failure(#""interaction":{"action":"close-overlay","destination":"m"}"#) == "Layer a: unsupported field interaction.destination")
    #expect(failure(#""interaction":{"action":"toggle-visibility"}"#) == "Layer a: missing interaction.targets")
    #expect(failure(#""interaction":{"action":"toggle-visibility","targets":[]}"#) == "Layer a: interaction.targets must be a non-empty array of layer ids")
    #expect(failure(#""interaction":{"action":"navigate","destination":"m","position":"center"}"#) == "Layer a: unsupported field interaction.position")
}

@Test func emptyStatesAreDroppedAndAnUpdateReplacesStatesWhole() throws {
    #expect(try node(#"{"id":"a","type":"rectangle","states":{}}"#).states == nil)
    var card = try decode(screens).nodes[0].children[0].children[0]
    try DesignJSON.apply(["states": ["pressed": ["fill": "#000000"]]], to: &card)
    #expect(card.states == LayerStates(pressed: LayerStyle(fill: .black)))
}

@Test func agentEditsMustPointAtExistingFramesAndLayers() throws {
    let document = try decode(screens)
    var toggle = DesignNode(id: "t", type: .rectangle)
    toggle.interaction = .toggleVisibility(targets: ["panel-a", "nope"])
    #expect(message { try Prototype.checkDestinations(of: toggle, in: document) } == "Layer t: interaction.targets includes nope, which is not a layer")
    toggle.interaction = .openOverlay(destination: "list", overlay: OverlaySettings(), transition: PrototypeTransition())
    #expect(message { try Prototype.checkDestinations(of: toggle, in: document) } == "Layer t: interaction.destination list is not a top-level frame")
    toggle.interaction = .toggleVisibility(targets: ["panel-a"])
    #expect(message { try Prototype.checkDestinations(of: toggle, in: document) } == nil)
}

// MARK: Scrolling

@Test func scrollingMovesTheContentWithinItsRangeAndKeepsFixedLayersOnTop() throws {
    let document = try decode(screens)
    var player = PrototypePlayer(start: "feed")
    // The header (on top, fixed) answers at the top; below it the list scrolls.
    #expect(player.target(at: Point(x: 10, y: 10), in: document).responder?.node.id == "header")
    let scrolled = player.scroll(by: Point(x: 0, y: 100), at: Point(x: 300, y: 100), in: document)
    #expect(scrolled)
    #expect(player.scrollOffsets["feed"] == Point(x: 0, y: 100))
    let scene = player.scene(in: document)
    let feed = try #require(scene.first)
    #expect(feed.children.map(\.id) == ["list", "header"])
    #expect(feed.children[0].y == -100 && feed.children[1].y == 0)
    // The card moved up with the content.
    #expect(player.target(at: Point(x: 30, y: 105), in: document).responder?.node.id == "open-dialog")
    // Clamped at both ends: the content is 1500 tall in a 600-tall frame.
    _ = player.scroll(by: Point(x: 0, y: 5000), at: Point(x: 300, y: 100), in: document)
    #expect(player.scrollOffsets["feed"] == Point(x: 0, y: 900))
    _ = player.scroll(by: Point(x: 0, y: -5000), at: Point(x: 300, y: 100), in: document)
    #expect(player.scrollOffsets["feed"] == Point(x: 0, y: 0))
    let stuck = player.scroll(by: Point(x: 0, y: -10), at: Point(x: 300, y: 100), in: document)
    #expect(!stuck)
    // The design document is never changed by playback.
    let original = try decode(screens)
    #expect(document == original)
}

@Test func theInnermostFrameThatCanMoveScrolls() throws {
    let document = try decode(screens)
    var player = PrototypePlayer(start: "feed")
    // A trackpad's vertical swipe over the horizontal carousel scrolls the page around it.
    let swiped = player.scroll(by: Point(x: 0, y: 50), at: Point(x: 100, y: 450), in: document)
    #expect(swiped && player.scrollOffsets["feed"] == Point(x: 0, y: 50) && player.scrollOffsets["carousel"] == nil)
    // A mouse wheel only turns vertically, so its delta scrolls the horizontal carousel under the pointer instead.
    let scrolled = player.scroll(by: Point(x: 0, y: 50), at: Point(x: 100, y: 400), wheel: true, in: document)
    #expect(scrolled)
    #expect(player.scrollOffsets["carousel"] == Point(x: 50, y: 0) && player.scrollOffsets["feed"] == Point(x: 0, y: 50))
    // At the carousel's start, scrolling back further moves nothing; a frame that does not overflow does not scroll.
    _ = player.scroll(by: Point(x: -50, y: 0), at: Point(x: 100, y: 400), in: document)
    let stuck = player.scroll(by: Point(x: -10, y: 0), at: Point(x: 100, y: 400), in: document)
    #expect(!stuck)
    #expect(Prototype.scrollRange(of: document.nodes[3]) == Size(width: 0, height: 0))
}

@Test func navigatingStartsTheDestinationAtTheTop() throws {
    var document = try decode(screens)
    document.nodes[3].children = [DesignNode(id: "x", type: .rectangle, x: 0, y: 0, width: 10, height: 10)]
    var player = PrototypePlayer(start: "feed")
    _ = player.scroll(by: Point(x: 0, y: 100), at: Point(x: 300, y: 300), in: document)
    _ = player.perform(.navigate(destination: "detail", transition: PrototypeTransition()), in: document)
    _ = player.perform(.navigate(destination: "feed", transition: PrototypeTransition()), in: document)
    #expect(player.scrollOffsets["feed"] == nil)
}

// MARK: States

@Test func hoverAndPressedStatesChangeTheLook() throws {
    let document = try decode(screens)
    let card = document.nodes[0].children[0].children[0]
    #expect(Prototype.style(of: card, hovered: true, pressed: false) == LayerStyle(fill: gray))
    // Pressed applies on top of hover.
    #expect(Prototype.style(of: card, hovered: true, pressed: true) == LayerStyle(fill: gray, opacity: 0.5))
    #expect(Prototype.style(of: card, hovered: false, pressed: false) == nil)
    let player = PrototypePlayer(start: "feed")
    #expect(player.target(at: Point(x: 30, y: 110), in: document).styled == "card")
    #expect(player.target(at: Point(x: 30, y: 210), in: document).styled == nil)
    let styled = player.scene(in: document, styles: ["card": LayerStyle(opacity: 0.5)])
    #expect(styled[0].children[0].children[0].opacity == 0.5 && styled[0].children[0].children[0].fill == .white)
}

// MARK: Overlays

@Test func anOverlayOpensBelowItsTriggerAndTakesAllInput() throws {
    let document = try decode(screens)
    var player = PrototypePlayer(start: "feed")
    let effect = player.click(at: Point(x: 30, y: 110), in: document)
    #expect(effect == .openOverlay(PrototypeOverlay(frame: "menu", settings: OverlaySettings(position: .belowTrigger),
                                                    transition: PrototypeTransition(), trigger: Rect(x: 20, y: 100, width: 100, height: 50))))
    #expect(!player.isTransitioning)
    let scene = player.scene(in: document)
    #expect(scene.map(\.id) == ["feed", "menu"])
    #expect(scene[1].x == 20 && scene[1].y == 150)
    // The frame below does not respond; a click outside closes the overlay, as this one allows.
    #expect(player.target(at: Point(x: 30, y: 310), in: document) == PrototypePlayer.Target(outside: true))
    let menu = player.overlays[0]
    #expect(player.click(at: Point(x: 30, y: 310), in: document) == .closeOverlay(menu))
    #expect(player.overlays.isEmpty)
    // Its close button closes it too, and Back does as well.
    _ = player.click(at: Point(x: 30, y: 110), in: document)
    #expect(player.target(at: Point(x: 25, y: 155), in: document).responder?.node.id == "close")
    let closed = player.click(at: Point(x: 25, y: 155), in: document)
    #expect(closed != nil && player.overlays.isEmpty)
    _ = player.click(at: Point(x: 30, y: 110), in: document)
    let back = player.perform(.back, in: document)
    #expect(back != nil && player.overlays.isEmpty && player.current == "feed")
}

@Test func aModalOverlayIgnoresOutsideClicksAndDrawsItsScrim() throws {
    let document = try decode(screens)
    var player = PrototypePlayer(start: "feed")
    _ = player.click(at: Point(x: 30, y: 210), in: document)
    #expect(player.isTransitioning)
    player.finishTransition()
    let scene = player.scene(in: document)
    #expect(scene.map(\.id) == ["feed", Prototype.scrimID("dialog"), "dialog"])
    #expect(scene[1].width == 400 && scene[1].height == 600 && scene[1].fill == dim)
    #expect(scene[2].x == 100 && scene[2].y == 200)
    let outside = player.click(at: Point(x: 5, y: 5), in: document)
    #expect(outside == nil && player.overlays.count == 1)
    let close = player.perform(.closeOverlay, in: document)
    #expect(close != nil)
    #expect(player.isTransitioning)
    // While it plays its closing transition the dialog is still drawn, but no longer takes input.
    #expect(player.scene(in: document).map(\.id) == ["feed", Prototype.scrimID("dialog"), "dialog"])
    #expect(player.target(at: Point(x: 30, y: 210), in: document).responder?.node.id == "open-dialog")
    player.finishTransition()
    #expect(player.scene(in: document).map(\.id) == ["feed"])
}

@Test func navigatingFromAnOverlayClosesItFirst() throws {
    let document = try decode(screens)
    var player = PrototypePlayer(start: "feed")
    _ = player.click(at: Point(x: 30, y: 110), in: document)
    #expect(player.click(at: Point(x: 125, y: 155), in: document) == .move(.init(from: "feed", to: "detail", transition: PrototypeTransition(), reversed: false)))
    #expect(player.overlays.isEmpty)
    // A frame on show cannot be opened as an overlay over itself.
    #expect(player.perform(.openOverlay(destination: "detail", overlay: OverlaySettings(), transition: PrototypeTransition()), in: document) == nil)
    #expect(Prototype.overlayOrigin(.bottom, size: Size(width: 200, height: 100), stage: Size(width: 400, height: 600),
                                    trigger: Rect(x: 0, y: 0, width: 0, height: 0)) == Point(x: 100, y: 500))
    // Kept inside the frame where it fits.
    #expect(Prototype.overlayOrigin(.belowTrigger, size: Size(width: 200, height: 100), stage: Size(width: 400, height: 600),
                                    trigger: Rect(x: 300, y: 550, width: 50, height: 50)) == Point(x: 200, y: 500))
}

// MARK: Toggles

@Test func aToggleSwapsVisibilityForThisPlaybackOnly() throws {
    let document = try decode(screens)
    var player = PrototypePlayer(start: "feed")
    func panels(_ player: PrototypePlayer) -> [Bool] { player.scene(in: document)[0].children[0].children[3...4].map(\.visible) }
    #expect(panels(player) == [true, false])
    #expect(player.click(at: Point(x: 30, y: 310), in: document) == .toggle)
    #expect(panels(player) == [false, true])
    // The newly shown panel takes clicks; the hidden one no longer does.
    #expect(player.target(at: Point(x: 210, y: 310), in: document) == PrototypePlayer.Target())
    _ = player.click(at: Point(x: 30, y: 310), in: document)
    #expect(panels(player) == [true, false])
    _ = player.click(at: Point(x: 30, y: 310), in: document)
    // A new playback starts from the document's own visibility, which playback never changed.
    #expect(panels(PrototypePlayer(start: "feed")) == [true, false])
    #expect(document.node("panel-b")?.visible == false)
    // Layers deleted since are skipped.
    #expect(player.perform(.toggleVisibility(targets: ["gone"]), in: document) == nil)
}
