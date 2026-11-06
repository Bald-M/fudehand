import Foundation
import Testing
import AtlasCore

private func catalogWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-atlas-catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("examples/demo"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("apps/atlas"), withIntermediateDirectories: true)
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
    let valid = try sampleCatalog()
    let mutations: [(String, (inout Catalog) -> Void)] = [
        ("version", { $0.version = 2 }),
        ("shell.port", { $0.shell.port = 0 }),
        ("本机 HTTP", { $0.shell.url = "https://127.0.0.1:4400/" }),
        ("id", { $0.projects.append($0.projects[0]) }),
        ("id", { $0.projects[0].id = "Bad ID" }),
        ("title", { $0.projects[0].title = "  " }),
        ("layoutVersion", { $0.projects[0].layoutVersion = 0 }),
        ("sourceUrl", { $0.projects[0].sourceUrl = "javascript:alert(1)" }),
        ("重复", { $0.projects[0].preview.port = 4400; $0.projects[0].enabled = false }),
        ("本机 HTTP", { $0.projects[0].preview.baseUrl = "http://example.com:4401/" }),
        ("端口", { $0.projects[0].preview.baseUrl = "http://127.0.0.1:4402/" }),
        ("账号", { $0.projects[0].preview.baseUrl = "http://user@127.0.0.1:4401/" }),
        ("cwd", { $0.projects[0].preview.cwd = "../outside" }),
        ("cwd", { $0.projects[0].preview.cwd = "examples/missing" }),
        ("command", { $0.projects[0].preview.command = [] }),
        ("command", { $0.projects[0].preview.command = ["pnpm", "bad\0command"] }),
        ("画框", { $0.projects[0].frames = [] }),
        ("id", { $0.projects[0].frames.append($0.projects[0].frames[0]) }),
        ("platform", { $0.projects[0].frames[0].platform = "tv" }),
        ("宽高", { $0.projects[0].frames[0].width = 0 }),
        ("宽高", { $0.projects[0].frames[0].height = .infinity }),
        ("坐标", { $0.projects[0].frames[0].x = .nan }),
        ("path", { $0.projects[0].frames[0].path = "//example.com/escape" }),
        ("path", { $0.projects[0].frames[0].path = "http://127.0.0.1:4402/escape" }),
        ("path", { $0.projects[0].frames[0].path = "\\\\example.com/escape" }),
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
    let encoded = try JSONEncoder().encode(valid)
    for field in ["title", "sourceUrl", "enabled", "frames", "preview"] {
        var raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var projects = try #require(raw["projects"] as? [[String: Any]])
        projects[0].removeValue(forKey: field)
        raw["projects"] = projects
        try JSONSerialization.data(withJSONObject: raw).write(to: root.appendingPathComponent("catalog.json"))
        do {
            _ = try Catalog.load(from: root)
            Issue.record("缺少必填字段未被拒绝：\(field)")
        } catch {
            #expect(error.localizedDescription.contains(field))
        }
    }
}
