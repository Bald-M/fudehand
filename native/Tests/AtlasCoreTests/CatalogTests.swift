import Foundation
import Testing
import AtlasCore

private func catalogWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("examples/demo"), withIntermediateDirectories: true)
    return root
}

@Test func catalogLoadsTheSharedConfigurationAndResolvesPreviewPaths() throws {
    let root = try catalogWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = try sampleCatalog()
    try JSONEncoder().encode(expected).write(to: root.appendingPathComponent("catalog.json"))
    let loaded = try Catalog.load(from: root)
    #expect(loaded == expected)
    try loaded.validate(root: root)
    #expect(try loaded.projects[0].frames[0].previewURL(baseURL: loaded.projects[0].preview.baseUrl).absoluteString == "http://127.0.0.1:4401/demo/home?view=mobile#top")
    #expect(try loaded.projects[0].frames[1].previewURL(baseURL: loaded.projects[0].preview.baseUrl).absoluteString == "http://127.0.0.1:4401/?view=web")
}

@Test func invalidCatalogConfigurationIsRejectedBeforeStartingAnyPreview() throws {
    let root = try catalogWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    // JSON cannot express non-finite numbers; the shared conformance file covers the other rules.
    let valid = try sampleCatalog()
    let mutations: [(String, (inout Catalog) -> Void)] = [
        ("宽高", { $0.projects[0].frames[0].height = .infinity }),
        ("坐标", { $0.projects[0].frames[0].x = .nan }),
    ]
    for (field, mutate) in mutations {
        var invalid = valid
        mutate(&invalid)
        do {
            try invalid.validate(root: root)
            Issue.record("无效配置未被拒绝：\(field)")
        } catch {
            #expect(error.localizedDescription.contains(field))
        }
    }
}

/// Runs tests/fixtures/catalog-conformance.json, which the Node launcher tests run too.
@Test func catalogValidationMatchesTheNodeLauncher() throws {
    let root = try catalogWorkspace()
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("examples/outside-link"), withDestinationURL: outside)
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/catalog-conformance.json")
    let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
    let cases = try #require(fixture["cases"] as? [[String: Any]])
    #expect(!cases.isEmpty)
    for testCase in cases {
        let name = testCase["name"] as? String ?? "?"
        let ops = try #require(testCase["ops"] as? [[String: Any]])
        var catalog: Any = try #require(fixture["catalog"])
        for op in ops { catalog = try applyConformanceOp(op, to: catalog) }
        try JSONSerialization.data(withJSONObject: catalog).write(to: root.appendingPathComponent("catalog.json"))
        let expected = testCase["error"] as? String
        do {
            _ = try Catalog.load(from: root)
            if let expected { Issue.record("\(name)：配置未被拒绝，期望错误包含 \(expected)") }
        } catch {
            if let expected {
                #expect(error.localizedDescription.contains(expected), "\(name)：\(error.localizedDescription)")
            } else {
                Issue.record("\(name)：有效配置被拒绝：\(error.localizedDescription)")
            }
        }
    }
}

private func applyConformanceOp(_ op: [String: Any], to value: Any) throws -> Any {
    let path = try #require(op["path"] as? [Any])
    func update(_ current: Any, _ keys: ArraySlice<Any>) throws -> Any {
        guard let key = keys.first else {
            guard op["op"] as? String == "appendCopy", var array = current as? [Any], let index = op["index"] as? Int else {
                throw ConformanceError()
            }
            array.append(array[index])
            return array
        }
        let rest = keys.dropFirst()
        let isLast = rest.isEmpty && op["op"] as? String != "appendCopy"
        if var object = current as? [String: Any], let key = key as? String {
            if isLast {
                if op["op"] as? String == "remove" { object.removeValue(forKey: key) } else { object[key] = op["value"] }
            } else {
                object[key] = try update(try #require(object[key]), rest)
            }
            return object
        }
        if var array = current as? [Any], let index = key as? Int {
            array[index] = isLast ? try #require(op["value"]) : try update(array[index], rest)
            return array
        }
        throw ConformanceError()
    }
    return try update(value, path[...])
}

private struct ConformanceError: Error {}
