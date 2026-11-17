import Foundation
import Testing
import AtlasCore

private func decode(_ json: String) throws -> DesignDocument { try DesignDocument.decode(Data(json.utf8)) }

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

let sampleDocument = """
{"format":"ui-atlas.design","version":1,"nodes":[
  {"id":"screen","type":"frame","name":"首页","x":0,"y":0,"width":390,"height":844,"fill":"#FFFFFF",
   "layout":{"direction":"vertical","spacing":12,"padding":{"top":16,"right":16,"bottom":16,"left":16},"align":"start","crossAlign":"stretch"},
   "children":[
     {"id":"title","type":"text","name":"标题","x":16,"y":16,"width":120,"height":28,
      "text":{"content":"今日计划","fontSize":22,"fontWeight":600,"color":"#111111","align":"left","autoResize":"height"},
      "sizing":{"horizontal":"fill","vertical":"hug"}},
     {"id":"card","type":"rectangle","name":"卡片","x":16,"y":56,"width":358,"height":80,"fill":"#F2F2F780",
      "stroke":{"color":"#000000","width":1},"cornerRadius":12,"opacity":0.5,"visible":false,"locked":true},
     {"id":"dot","type":"ellipse","name":"点","x":0,"y":0,"width":10,"height":10}
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
    #expect(text.contains("\"format\" : \"ui-atlas.design\""))
    #expect(text.contains("\"version\" : 1"))
    #expect(text.range(of: "\"format\"")!.lowerBound < text.range(of: "\"nodes\"")!.lowerBound)
}

@Test func colorHexForms() throws {
    #expect(try DesignColor(hex: "#ff0000") == DesignColor(r: 1, g: 0, b: 0, a: 1))
    #expect(DesignColor(r: 1, g: 0, b: 0, a: 1).hex == "#FF0000")
    #expect(DesignColor(r: 0, g: 0, b: 0, a: 0.5).hex == "#00000080")
    #expect(message { _ = try DesignColor(hex: "red") } == "颜色格式应为 #RRGGBB 或 #RRGGBBAA：red")
}

@Test func rejectsNewerVersion() {
    #expect(message { _ = try decode(#"{"format":"ui-atlas.design","version":2,"nodes":[]}"#) }
            == "文件由更新版本的 ui-atlas 创建（格式版本 2），请升级后再打开")
}

@Test func rejectsWrongFormat() {
    #expect(message { _ = try decode(#"{"format":"figma","version":1,"nodes":[]}"#) } == "不是 ui-atlas 工程文件")
    #expect(message { _ = try decode("not json") } == "不是 ui-atlas 工程文件")
}

@Test func rejectsDuplicateIDs() {
    let json = #"{"format":"ui-atlas.design","version":1,"nodes":[{"id":"a","type":"rectangle","name":"","x":0,"y":0,"width":1,"height":1},{"id":"a","type":"ellipse","name":"","x":0,"y":0,"width":1,"height":1}]}"#
    #expect(message { _ = try decode(json) } == "图层 id 重复：a")
}

@Test func rejectsFieldsOnWrongType() {
    let missingText = #"{"format":"ui-atlas.design","version":1,"nodes":[{"id":"t","type":"text","name":"","x":0,"y":0,"width":1,"height":1}]}"#
    #expect(message { _ = try decode(missingText) } == "图层 t：文字图层缺少 text")
    let layoutOnEllipse = #"{"format":"ui-atlas.design","version":1,"nodes":[{"id":"e","type":"ellipse","name":"","x":0,"y":0,"width":1,"height":1,"layout":{"direction":"vertical","spacing":0,"padding":{"top":0,"right":0,"bottom":0,"left":0},"align":"start","crossAlign":"start"}}]}"#
    #expect(message { _ = try decode(layoutOnEllipse) } == "图层 e：ellipse 不支持 layout")
    let negative = #"{"format":"ui-atlas.design","version":1,"nodes":[{"id":"r","type":"rectangle","name":"","x":0,"y":0,"width":-1,"height":1}]}"#
    #expect(message { _ = try decode(negative) } == "图层 r：width 不能为负数")
}
