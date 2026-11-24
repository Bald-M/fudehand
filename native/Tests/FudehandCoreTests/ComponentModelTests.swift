import Foundation
import Testing
import FudehandCore

private func decode(_ json: String) throws -> DesignDocument { try DesignDocument.decode(Data(json.utf8)) }

private func message(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as DesignError { return error.message } catch { return "\(error)" }
}

private func frame(_ id: String, _ extra: String = "", children: String = "") -> String {
    "{\"id\":\"\(id)\",\"type\":\"frame\",\"x\":0,\"y\":0,\"width\":10,\"height\":10\(extra)\(children.isEmpty ? "" : ",\"children\":[\(children)]")}"
}

private func file(_ nodes: String, version: Int = 10) -> String {
    "{\"format\":\"fudehand.design\",\"version\":\(version),\"nodes\":[\(nodes)]}"
}

@Suite struct ComponentModelTests {
    @Test func roundTripsComponentFields() throws {
        var main = DesignNode(id: "m", type: .frame)
        main.component = true
        main.children = [DesignNode(id: "m-title", type: .frame)]
        var root = DesignNode(id: "i", type: .frame)
        root.instance = "m"; root.source = "m"; root.overrides = ["text.content", "fill"]
        var child = DesignNode(id: "i-title", type: .frame)
        child.source = "m-title"
        root.children = [child]
        let document = DesignDocument(nodes: [main, root])
        let data = try document.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 11)
        let nodes = try #require(object["nodes"] as? [[String: Any]])
        #expect(nodes[1]["overrides"] as? [String] == ["fill", "text.content"])
        #expect(try DesignDocument.decode(data) == document)
    }

    @Test func omitsUnsetComponentFields() {
        let object = DesignJSON.object(DesignNode(id: "a", type: .rectangle), includeImageData: true)
        for key in DesignJSON.componentKeys { #expect(object[key] == nil) }
    }

    @Test func version9FileOpens() throws {
        let document = try decode(file(frame("a"), version: 9))
        let object = try #require(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
        #expect(object["version"] as? Int == 11)
    }

    @Test func componentInsideInstanceIsLoadError() {
        let json = file(frame("i", ",\"instance\":\"m\"", children: frame("c", ",\"component\":true")))
        #expect(message { _ = try decode(json) } != nil)
    }

    @Test func componentInsideComponentIsLoadError() {
        let json = file(frame("m", ",\"component\":true", children: frame("c", ",\"component\":true")))
        #expect(message { _ = try decode(json) } != nil)
    }

    @Test func instanceCannotBeComponent() {
        #expect(message { _ = try decode(file(frame("m", ",\"component\":true,\"instance\":\"x\""))) } != nil)
    }

    @Test func sourceOutsideInstanceIsLoadError() {
        #expect(message { _ = try decode(file(frame("a", ",\"source\":\"m\""))) } != nil)
        #expect(message { _ = try decode(file(frame("a", ",\"overrides\":[\"fill\"]"))) } != nil)
    }

    @Test func nestedInstanceRootInsideInstanceIsAllowed() throws {
        let b = frame("b", ",\"component\":true", children: frame("b1"))
        let m = frame("m", ",\"component\":true",
                      children: frame("m-b", ",\"instance\":\"b\",\"source\":\"b\"", children: frame("m-b1", ",\"source\":\"b1\"")))
        let i = frame("i", ",\"instance\":\"m\",\"source\":\"m\"",
                      children: frame("n", ",\"instance\":\"b\",\"source\":\"m-b\"", children: frame("n1", ",\"source\":\"m-b1\"")))
        let document = try decode(file([b, m, i].joined(separator: ",")))
        #expect(document.nodes[2].children[0].instance == "b")
    }

    @Test func missingMainComponentIsNotALoadError() throws {
        _ = try decode(file(frame("i", ",\"instance\":\"gone\",\"source\":\"gone\"")))
    }

    @Test func componentFieldsCannotBePatched() {
        let changes: [String: Any] = ["overrides": [String](), "component": true, "instance": "m", "source": "m"]
        for (key, value) in changes {
            var node = DesignNode(id: "a", type: .frame)
            let before = node
            let text = message { try DesignJSON.apply([key: value], to: &node) }
            #expect(text == "Layer a: cannot change \(key)")
            #expect(node == before)
        }
    }
}
