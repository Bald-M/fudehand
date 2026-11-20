import Foundation
import Testing
import FudehandCore

private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func snapshotObject(_ record: [String: Any], type: String = "image") -> [String: Any] {
    var object: [String: Any] = ["id": "s", "type": type, "versionSnapshot": record]
    if type == "image" { object["image"] = ["data": png.base64EncodedString()] }
    return object
}

@Test func version6IsWrittenAndVersion5Opens() throws {
    #expect(DesignDocument.formatVersion >= 6)
    let json = #"{"format":"fudehand.design","version":5,"nodes":[{"id":"r","type":"rectangle","name":"","x":0,"y":0,"width":1,"height":1}]}"#
    #expect(try DesignDocument.decode(Data(json.utf8)).nodes.count == 1)
}

/// A document with a top-level frame `home` at (100, 50), 390 × 844, holding a nested frame `card`.
private func document() -> DesignDocument {
    var home = DesignNode(id: "home", type: .frame, name: "Home", x: 100, y: 50, width: 390, height: 844)
    home.children = [DesignNode(id: "card", type: .frame, name: "Card", x: 20, y: 30, width: 200, height: 120)]
    return DesignDocument(nodes: [home])
}

@Test func versionSnapshotRoundTripsThroughTheProjectFile() throws {
    let node = try DesignJSON.node(from: snapshotObject(["frame": "home", "createdAt": "2026-11-20T09:30:00Z", "note": "Before"]))
    let snapshot = try #require(node.versionSnapshot)
    #expect(snapshot.frame == "home" && snapshot.note == "Before" && snapshot.timestamp == "2026-11-20T09:30:00Z")
    let data = try DesignDocument(nodes: [node]).encoded()
    #expect(try DesignDocument.decode(data).nodes == [node])
    // An empty note is left out of the file.
    var plain = node
    plain.versionSnapshot?.note = ""
    #expect((DesignJSON.object(plain, includeImageData: false)["versionSnapshot"] as? [String: Any])?.keys.sorted() == ["createdAt", "frame"])
}

@Test func versionSnapshotFieldsAreValidated() {
    #expect(message { _ = try DesignJSON.node(from: snapshotObject(["frame": "home", "createdAt": "2026-11-20T09:30:00Z"], type: "rectangle")) }
            == "Layer s: rectangle does not support versionSnapshot")
    #expect(message { _ = try DesignJSON.node(from: snapshotObject(["frame": "", "createdAt": "2026-11-20T09:30:00Z"])) }
            == "Layer s: versionSnapshot.frame must be a non-empty frame id")
    #expect(message { _ = try DesignJSON.node(from: snapshotObject(["frame": "home", "createdAt": "yesterday"])) }
            == "Layer s: versionSnapshot.createdAt must be an ISO 8601 date and time such as 2026-11-20T09:30:00Z; got yesterday")
    #expect(message { _ = try DesignJSON.node(from: snapshotObject(["frame": "home"])) } == "Layer s: missing versionSnapshot.createdAt")
    #expect(message { _ = try DesignJSON.node(from: snapshotObject(["frame": "home", "createdAt": "2026-11-20T09:30:00Z", "by": "me"])) }
            == "Layer s: unsupported field versionSnapshot.by")
}

@Test func updatingTheNoteKeepsTheRestOfTheRecord() throws {
    var node = try DesignJSON.node(from: snapshotObject(["frame": "home", "createdAt": "2026-11-20T09:30:00Z"]))
    try DesignJSON.apply(["versionSnapshot": ["note": "After review"]], to: &node)
    #expect(node.versionSnapshot?.frame == "home" && node.versionSnapshot?.note == "After review")
    #expect(node.versionSnapshot?.timestamp == "2026-11-20T09:30:00Z")
}

@Test func createdAtKeepsWholeSeconds() {
    let snapshot = VersionSnapshot(frame: "home", createdAt: Date(timeIntervalSince1970: 1_000.75))
    #expect(snapshot.createdAt == Date(timeIntervalSince1970: 1_000))
}

@Test func newSnapshotsLineUpToTheRightOfTheFrame() throws {
    var doc = document()
    let date = Date(timeIntervalSince1970: 0)
    let home = try #require(doc.node("home"))
    let first = try #require(VersionSnapshot.layer(id: "s1", of: home, png: png, in: doc, note: "One", at: date))
    #expect(first.frame == Rect(x: 490 + VersionSnapshot.gap, y: 50, width: 390, height: 844))
    #expect(first.type == .image && first.image?.fit == .stretch && first.versionSnapshot?.note == "One" && first.name == "Home Snapshot")
    try doc.insert(first, parent: nil, index: nil)
    let second = try #require(VersionSnapshot.layer(id: "s2", of: home, png: png, in: doc))
    #expect(second.x == first.frame.maxX + VersionSnapshot.gap && second.y == 50)
    try doc.insert(second, parent: nil, index: nil)
    // Placing the first one beside the frame again skips only itself.
    #expect(VersionSnapshot.besidePosition(of: "home", excluding: "s1", in: doc) == Point(x: second.frame.maxX + VersionSnapshot.gap, y: 50))
    #expect(doc.versionSnapshots().map(\.id) == ["s1", "s2"])
    #expect(doc.versionSnapshots(of: "card").isEmpty)
}

@Test func aNestedFrameIsSnapshotInCanvasCoordinates() throws {
    let doc = document()
    let card = try #require(doc.node("card"))
    let layer = try #require(VersionSnapshot.layer(id: "s", of: card, png: png, in: doc))
    // Beside its screen, not on top of it: right of Home (100 + 390), level with the card.
    #expect(layer.frame == Rect(x: 490 + VersionSnapshot.gap, y: 80, width: 200, height: 120))
    #expect(VersionSnapshot.besidePosition(of: "missing", in: doc) == nil)
}
