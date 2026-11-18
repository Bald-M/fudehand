import Foundation
import Testing
import FudehandCore

private func decode(_ json: String) throws -> DesignDocument { try DesignDocument.decode(Data(json.utf8)) }

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func node(_ json: String) throws -> DesignNode { try DesignJSON.node(from: try JSONSerialization.jsonObject(with: Data(json.utf8))) }

/// Home has a card (with a nested label) that goes to Detail, a hidden button, and a group; Detail has a back button.
private let prototype = """
{"format":"fudehand.design","version":2,"nodes":[
  {"id":"home","type":"frame","x":0,"y":0,"width":390,"height":844,"children":[
    {"id":"card","type":"rectangle","x":20,"y":100,"width":200,"height":100,
     "interaction":{"action":"navigate","destination":"detail","transition":{"type":"push-left","duration":0.25,"easing":"ease-in-out"}}},
    {"id":"panel","type":"frame","x":20,"y":300,"width":200,"height":100,
     "interaction":{"action":"navigate","destination":"detail","transition":{"type":"sheet"}},
     "children":[{"id":"label","type":"text","x":10,"y":10,"width":50,"height":20,"text":{"content":"Open"}}]},
    {"id":"hidden","type":"rectangle","x":20,"y":500,"width":200,"height":100,"visible":false,
     "interaction":{"action":"navigate","destination":"detail"}},
    {"id":"gone","type":"rectangle","x":20,"y":700,"width":200,"height":100,
     "interaction":{"action":"navigate","destination":"deleted-frame"}}
  ]},
  {"id":"detail","type":"frame","x":500,"y":0,"width":390,"height":844,"children":[
    {"id":"back","type":"rectangle","x":0,"y":0,"width":44,"height":44,"interaction":{"action":"back"}},
    {"id":"loop","type":"rectangle","x":0,"y":100,"width":44,"height":44,
     "interaction":{"action":"navigate","destination":"inner"}},
    {"id":"inner","type":"frame","x":0,"y":200,"width":44,"height":44}
  ]}
]}
"""

// MARK: Reading and writing

@Test func readsAndWritesInteractions() throws {
    let document = try decode(prototype)
    let home = document.nodes[0]
    #expect(home.children[0].interaction == .navigate(destination: "detail",
                                                      transition: PrototypeTransition(type: .pushLeft, duration: 0.25, easing: .easeInOut)))
    // Omitted transition fields take their defaults.
    #expect(home.children[1].interaction == .navigate(destination: "detail", transition: PrototypeTransition(type: .sheet, duration: 0.3, easing: .easeOut)))
    #expect(home.children[2].interaction == .navigate(destination: "detail", transition: PrototypeTransition()))
    #expect(document.nodes[1].children[0].interaction == .back)
    #expect(try DesignDocument.decode(try document.encoded()) == document)
    let back = DesignJSON.object(document.nodes[1].children[0], includeImageData: false)
    #expect(back["interaction"] as? [String: String] == ["action": "back"])
}

@Test func versionOneFilesOpenAndAreSavedAsVersionTwo() throws {
    let old = try decode(#"{"format":"fudehand.design","version":1,"nodes":[{"id":"a","type":"frame"}]}"#)
    #expect(old.nodes[0].interaction == nil)
    let text = String(decoding: try old.encoded(), as: UTF8.self)
    #expect(text.contains("\"version\" : 2"))
    #expect(message { _ = try decode(#"{"format":"fudehand.design","version":3,"nodes":[]}"#) }
            == "File was created by a newer version of Fudehand (format version 3); upgrade Fudehand to open it")
}

@Test func validatesInteractionFields() {
    func failure(_ interaction: String) -> String? {
        message { _ = try node(#"{"id":"a","type":"rectangle","interaction":"# + interaction + "}") }
    }
    #expect(failure(#"{"action":"jump"}"#) == "Layer a: interaction.action must be one of navigate, back; got jump")
    #expect(failure(#"{}"#) == "Layer a: missing interaction.action")
    #expect(failure(#"{"action":"navigate"}"#) == "Layer a: missing interaction.destination")
    #expect(failure(#"{"action":"navigate","destination":""}"#) == "Layer a: interaction.destination must be a non-empty frame id")
    #expect(failure(#"{"action":"back","destination":"x"}"#) == "Layer a: unsupported field interaction.destination")
    #expect(failure(#"{"action":"navigate","destination":"x","transition":{"type":"zoom"}}"#)
            == "Layer a: interaction.transition.type must be one of none, dissolve, push-left, push-right, push-up, push-down, sheet; got zoom")
    #expect(failure(#"{"action":"navigate","destination":"x","transition":{"duration":11}}"#)
            == "Layer a: interaction.transition.duration must not be greater than 10")
    #expect(failure(#"{"action":"navigate","destination":"x","transition":{"easing":"bounce"}}"#)
            == "Layer a: interaction.transition.easing must be one of linear, ease-in, ease-out, ease-in-out; got bounce")
    #expect(failure(#"{"action":"navigate","destination":"x","trigger":"hover"}"#) == "Layer a: unsupported field interaction.trigger")
    #expect(failure(#""back""#) == "Layer a: interaction must be an object")
}

@Test func anUpdateReplacesTheWholeInteraction() throws {
    var card = try decode(prototype).nodes[0].children[0]
    try DesignJSON.apply(["interaction": ["action": "back"]], to: &card)
    #expect(card.interaction == .back)
    try DesignJSON.apply(["interaction": NSNull()], to: &card)
    #expect(card.interaction == nil)
}

// MARK: Playback

@Test func startsFromTheSelectedTopLevelFrameOrTheFirstOne() throws {
    let document = try decode(prototype)
    #expect(Prototype.startFrame(in: document, selection: []) == "home")
    #expect(Prototype.startFrame(in: document, selection: ["detail"]) == "detail")
    #expect(Prototype.startFrame(in: document, selection: ["inner"]) == "detail")
    #expect(Prototype.startFrame(in: DesignDocument(nodes: [DesignNode(id: "r", type: .rectangle)]), selection: []) == nil)
}

@Test func theNearestAncestorWithAnInteractionAnswersAClick() throws {
    let home = try decode(prototype).nodes[0]
    #expect(Prototype.responder(in: home, at: Point(x: 30, y: 110))?.id == "card")
    // The label has no interaction, so its frame answers.
    #expect(Prototype.responder(in: home, at: Point(x: 35, y: 315))?.id == "panel")
    // Hidden layers never answer; neither does empty space without an interaction, nor a point outside the frame.
    #expect(Prototype.responder(in: home, at: Point(x: 30, y: 510)) == nil)
    #expect(Prototype.responder(in: home, at: Point(x: 300, y: 20)) == nil)
    #expect(Prototype.responder(in: home, at: Point(x: 400, y: 110)) == nil)
}

@Test func goesToAFrameAndBackInReverse() throws {
    let document = try decode(prototype)
    var player = PrototypePlayer(start: "home")
    let push = PrototypeTransition(type: .pushLeft, duration: 0.25, easing: .easeInOut)
    #expect(player.click(at: Point(x: 30, y: 110), in: document) == .init(from: "home", to: "detail", transition: push, reversed: false))
    #expect(player.current == "detail" && player.isTransitioning)
    // A click while the transition plays is ignored.
    #expect(player.click(at: Point(x: 10, y: 10), in: document) == nil)
    player.finishTransition()
    #expect(player.click(at: Point(x: 10, y: 10), in: document) == .init(from: "detail", to: "home", transition: push, reversed: true))
    player.finishTransition()
    #expect(player.current == "home" && !player.canGoBack)
    // Back with nowhere to go does nothing.
    #expect(player.perform(.back, in: document) == nil)
}

@Test func onlyExistingTopLevelFramesAreDestinations() throws {
    let document = try decode(prototype)
    var player = PrototypePlayer(start: "home")
    #expect(player.click(at: Point(x: 30, y: 710), in: document) == nil)
    #expect(player.current == "home" && !player.isTransitioning)
    _ = player.click(at: Point(x: 30, y: 110), in: document)
    player.finishTransition()
    // "inner" is a frame, but not a top-level one.
    #expect(player.click(at: Point(x: 10, y: 110), in: document) == nil)
}

@Test func backSkipsFramesDeletedSinceTheyWereShown() throws {
    var document = try decode(prototype)
    document.nodes.append(DesignNode(id: "third", type: .frame))
    var player = PrototypePlayer(start: "home")
    _ = player.perform(.navigate(destination: "detail", transition: PrototypeTransition()), in: document)
    _ = player.perform(.navigate(destination: "third", transition: PrototypeTransition()), in: document)
    #expect(!player.isTransitioning)
    try document.delete(["detail"])
    #expect(player.perform(.back, in: document)?.to == "home")
}
