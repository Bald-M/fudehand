import Foundation
import Testing
@testable import FudehandCore

private func decode(_ json: String) throws -> DesignDocument { try DesignDocument.decode(Data(json.utf8)) }

private func message(_ json: String) -> String? {
    do { _ = try decode(json); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func frame(_ id: String, _ extra: String = "", children: String = "") -> String {
    "{\"id\":\"\(id)\",\"type\":\"frame\",\"x\":0,\"y\":0,\"width\":10,\"height\":10\(extra)\(children.isEmpty ? "" : ",\"children\":[\(children)]")}"
}

private func file(_ nodes: String, version: Int = 11) -> String {
    "{\"format\":\"fudehand.design\",\"version\":\(version),\"nodes\":[\(nodes)]}"
}

private func variant(_ id: String, _ values: String) -> String { frame(id, ",\"component\":true,\"variant\":\(values)") }

private func set(_ id: String = "set", properties: String = "[\"State\"]", _ extra: String = "", children: String) -> String {
    frame(id, ",\"componentSet\":\(properties)\(extra)", children: children)
}

@Suite struct VariantModelTests {
    @Test func roundTripsSetAndVariantFields() throws {
        var a = DesignNode(id: "a", type: .frame)
        a.component = true; a.variant = ["State": "Default", "Size": "Small"]
        var b = DesignNode(id: "b", type: .frame)
        b.component = true; b.variant = ["State": "Hover", "Size": "Small"]
        var container = DesignNode(id: "set", type: .frame)
        container.componentSet = ["State", "Size"]
        container.children = [a, b]
        let document = DesignDocument(nodes: [container])
        let data = try document.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 11)
        let nodes = try #require(object["nodes"] as? [[String: Any]])
        #expect(nodes[0]["componentSet"] as? [String] == ["State", "Size"])
        #expect((nodes[0]["children"] as? [[String: Any]])?[0]["variant"] as? [String: String] == ["State": "Default", "Size": "Small"])
        #expect(try DesignDocument.decode(data) == document)
    }

    @Test func version10FileOpens() throws {
        let document = try decode(file(frame("a"), version: 10))
        let object = try #require(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
        #expect(object["version"] as? Int == 11)
    }

    @Test func layerWithoutComponentFieldsHasNoBox() throws {
        let document = try decode(file(frame("a")))
        #expect(document.nodes[0].componentSet == nil && document.nodes[0].variant == nil)
        #expect(document.nodes[0].componentBox == nil)
        var node = DesignNode(id: "n", type: .frame)
        node.componentSet = ["State"]
        node.componentSet = nil
        #expect(node.componentBox == nil)
    }

    @Test func omitsUnsetFields() {
        let object = DesignJSON.object(DesignNode(id: "a", type: .rectangle), includeImageData: true)
        #expect(object["componentSet"] == nil && object["variant"] == nil)
        #expect(DesignJSON.componentKeys.isSuperset(of: ["componentSet", "variant"]))
    }

    @Test func validSetOpens() throws {
        let document = try decode(file(set(children: variant("a", "{\"State\":\"Default\"}") + "," + variant("b", "{\"State\":\"Hover\"}"))))
        #expect(document.nodes[0].children.count == 2)
    }

    @Test func emptySetOpens() throws {
        _ = try decode(file(set(properties: "[]", children: "")))
    }

    @Test func setMustBeFrame() {
        let json = file("{\"id\":\"set\",\"type\":\"rectangle\",\"x\":0,\"y\":0,\"width\":1,\"height\":1,\"componentSet\":[\"State\"]}")
        #expect(message(json)?.contains("set") == true)
        #expect(message(json)?.contains("frame") == true)
    }

    @Test func setCannotBeAMainComponentOrInstance() {
        let main = file(set("set", ",\"component\":true", children: ""))
        #expect(message(main)?.contains("Layer set") == true)
        let inst = file(set("set", ",\"instance\":\"m\"", children: ""))
        #expect(message(inst)?.contains("Layer set") == true)
    }

    @Test func setNotInsideComponentInstanceOrSet() {
        let inComponent = file(frame("m", ",\"component\":true", children: set(children: "")))
        #expect(message(inComponent)?.contains("Layer set") == true)
        let inInstance = file(frame("i", ",\"instance\":\"m\"", children: set(children: "")))
        #expect(message(inInstance)?.contains("Layer set") == true)
        let inSet = file(set("outer", children: set("inner", children: "")))
        #expect(message(inSet)?.contains("Layer inner") == true)
    }

    @Test func setChildrenMustBeVariants() {
        let plain = file(set(children: frame("x")))
        #expect(message(plain)?.contains("Layer x") == true)
        let mainWithoutVariant = file(set(children: frame("x", ",\"component\":true")))
        #expect(message(mainWithoutVariant)?.contains("Layer x") == true)
    }

    @Test func variantOnlyInSet() {
        let loose = file(frame("v", ",\"component\":true,\"variant\":{\"State\":\"A\"}"))
        #expect(message(loose)?.contains("Layer v") == true)
        let inPlainFrame = file(frame("p", children: variant("v", "{\"State\":\"A\"}")))
        #expect(message(inPlainFrame)?.contains("Layer v") == true)
    }

    @Test func variantKeysMatchSetProperties() {
        let missing = file(set(properties: "[\"State\",\"Size\"]", children: variant("v", "{\"State\":\"A\"}")))
        #expect(message(missing)?.contains("Layer v") == true)
        let extra = file(set(children: variant("v", "{\"State\":\"A\",\"Size\":\"S\"}")))
        #expect(message(extra)?.contains("Layer v") == true)
    }

    @Test func variantValuesNonEmpty() {
        #expect(message(file(set(children: variant("v", "{\"State\":\"\"}"))))?.contains("Layer v") == true)
    }

    @Test func variantValuesUnique() {
        let json = file(set(children: variant("a", "{\"State\":\"A\"}") + "," + variant("b", "{\"State\":\"A\"}")))
        #expect(message(json)?.contains("Layer b") == true)
    }

    @Test func propertyNamesUniqueNonEmpty() {
        #expect(message(file(set(properties: "[\"State\",\"State\"]", children: "")))?.contains("Layer set") == true)
        #expect(message(file(set(properties: "[\"\"]", children: "")))?.contains("Layer set") == true)
    }

    @Test func malformedFieldTypesAreRejected() {
        #expect(message(file(frame("a", ",\"componentSet\":\"State\"")))?.contains("componentSet") == true)
        #expect(message(file(frame("a", ",\"variant\":[\"x\"]")))?.contains("variant") == true)
        #expect(message(file(frame("a", ",\"variant\":{\"State\":1}")))?.contains("variant") == true)
    }
}
