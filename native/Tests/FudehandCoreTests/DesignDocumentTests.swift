import Foundation
import Testing
import FudehandCore

private func decode(_ json: String) throws -> DesignDocument { try DesignDocument.decode(Data(json.utf8)) }

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

let sampleDocument = """
{"format":"fudehand.design","version":1,"nodes":[
  {"id":"screen","type":"frame","name":"Home","x":0,"y":0,"width":390,"height":844,"fill":"#FFFFFF",
   "layout":{"direction":"vertical","spacing":12,"padding":{"top":16,"right":16,"bottom":16,"left":16},"align":"start","crossAlign":"stretch"},
   "children":[
     {"id":"title","type":"text","name":"Title","x":16,"y":16,"width":120,"height":28,
      "text":{"content":"Today","fontSize":22,"fontWeight":600,"color":"#111111","align":"left","autoResize":"height"},
      "sizing":{"horizontal":"fill","vertical":"hug"}},
     {"id":"card","type":"rectangle","name":"Card","x":16,"y":56,"width":358,"height":80,"fill":"#F2F2F780",
      "stroke":{"color":"#000000","width":1},"cornerRadius":12,"opacity":0.5,"visible":false,"locked":true},
     {"id":"dot","type":"ellipse","name":"Dot","x":0,"y":0,"width":10,"height":10}
   ]}
]}
"""

@Test func roundTripsDocument() throws {
    let document = try decode(sampleDocument)
    #expect(document.nodes.count == 1)
    let screen = document.nodes[0]
    #expect(screen.type == .frame && screen.layout?.spacing == 12 && screen.children.count == 3)
    let card = screen.children[1]
    #expect(card.fill == DesignColor(r: 242 / 255, g: 242 / 255, b: 247 / 255, a: 128 / 255))
    #expect(card.visible == false && card.locked == true && card.opacity == 0.5 && card.cornerRadius == 12)
    #expect(screen.children[0].sizing == Sizing(horizontal: .fill, vertical: .hug))
    let again = try DesignDocument.decode(try document.encoded())
    #expect(again == document)
}

@Test func encodesSortedKeysWithFormatHeader() throws {
    let text = String(decoding: try DesignDocument(nodes: []).encoded(), as: UTF8.self)
    #expect(text.contains("\"format\" : \"fudehand.design\""))
    #expect(text.contains("\"version\" : 3"))
    #expect(text.range(of: "\"format\"")!.lowerBound < text.range(of: "\"nodes\"")!.lowerBound)
}

@Test func colorHexForms() throws {
    #expect(try DesignColor(hex: "#ff0000") == DesignColor(r: 1, g: 0, b: 0, a: 1))
    #expect(DesignColor(r: 1, g: 0, b: 0, a: 1).hex == "#FF0000")
    #expect(DesignColor(r: 0, g: 0, b: 0, a: 0.5).hex == "#00000080")
    #expect(message { _ = try DesignColor(hex: "red") } == "Color must be #RRGGBB or #RRGGBBAA: red")
}

@Test func colorRejectsSignedHex() {
    #expect(message { _ = try DesignColor(hex: "#+12345") } == "Color must be #RRGGBB or #RRGGBBAA: #+12345")
    #expect(message { _ = try DesignColor(hex: "#-00000") } == "Color must be #RRGGBB or #RRGGBBAA: #-00000")
    #expect(message { _ = try DesignColor(hex: "#+1234567") } == "Color must be #RRGGBB or #RRGGBBAA: #+1234567")
}

@Test func rejectsNewerVersion() {
    #expect(message { _ = try decode(#"{"format":"fudehand.design","version":4,"nodes":[]}"#) }
            == "File was created by a newer version of Fudehand (format version 4); upgrade Fudehand to open it")
}

@Test func rejectsMissingOrInvalidVersion() {
    #expect(message { _ = try decode(#"{"format":"fudehand.design","version":0,"nodes":[]}"#) } == "Project file is missing its format version")
    #expect(message { _ = try decode(#"{"format":"fudehand.design","nodes":[]}"#) } == "Project file is missing its format version")
}

@Test func rejectsWrongFormat() {
    #expect(message { _ = try decode(#"{"format":"figma","version":1,"nodes":[]}"#) } == "Not a Fudehand project file")
    #expect(message { _ = try decode("not json") } == "Not a Fudehand project file")
    // A file saved before the rename to Fudehand still opens once it has the new extension.
    #expect((try? decode(#"{"format":"ui-atlas.design","version":1,"nodes":[]}"#))?.nodes.isEmpty == true)
}

@Test func rejectsDuplicateIDs() {
    let json = #"{"format":"fudehand.design","version":1,"nodes":[{"id":"a","type":"rectangle","name":"","x":0,"y":0,"width":1,"height":1},{"id":"a","type":"ellipse","name":"","x":0,"y":0,"width":1,"height":1}]}"#
    #expect(message { _ = try decode(json) } == "Duplicate layer id: a")
}

@Test func rejectsFieldsOnWrongType() {
    let missingText = #"{"format":"fudehand.design","version":1,"nodes":[{"id":"t","type":"text","name":"","x":0,"y":0,"width":1,"height":1}]}"#
    #expect(message { _ = try decode(missingText) } == "Layer t: text layer is missing text")
    let layoutOnEllipse = #"{"format":"fudehand.design","version":1,"nodes":[{"id":"e","type":"ellipse","name":"","x":0,"y":0,"width":1,"height":1,"layout":{"direction":"vertical","spacing":0,"padding":{"top":0,"right":0,"bottom":0,"left":0},"align":"start","crossAlign":"start"}}]}"#
    #expect(message { _ = try decode(layoutOnEllipse) } == "Layer e: ellipse does not support layout")
    let negative = #"{"format":"fudehand.design","version":1,"nodes":[{"id":"r","type":"rectangle","name":"","x":0,"y":0,"width":-1,"height":1}]}"#
    #expect(message { _ = try decode(negative) } == "Layer r: width must not be negative")
}
