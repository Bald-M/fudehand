import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

private func project(_ id: String, enabled: Bool = true, port: Int) -> Project {
    let preview = Preview(cwd: "examples/\(id)", command: ["pnpm", "dev"], port: port, baseUrl: "http://127.0.0.1:\(port)/")
    let frames = [
        Frame(id: "home", title: "首页", platform: "web", path: "/", width: 1440, height: 900, x: 0, y: 0),
        Frame(id: "phone", title: "手机", platform: "mobile", path: "/m", width: 390, height: 844, x: 1600, y: 0),
    ]
    return Project(id: id, title: "作品 \(id)", subtitle: "", description: "", author: "", sourceUrl: nil,
                   framework: "HTML", tags: [], enabled: enabled, layoutVersion: 1, preview: preview, frames: frames)
}

@MainActor private func controlledStore() -> AtlasStore {
    let store = AtlasStore()
    store.catalog = Catalog(version: 1, projects: [project("a", port: 4401), project("b", port: 4402), project("off", enabled: false, port: 4403)])
    store.select(store.catalog!.projects[0])
    return store
}

@MainActor private func failure(_ store: AtlasStore, _ command: ControlCommand) async -> String? {
    do { _ = try await store.handleControl(command); return nil }
    catch { return error.localizedDescription }
}

@Test @MainActor func controlStateDescribesProjectFramesAndViewport() async throws {
    let store = controlledStore()
    store.selection = ["phone"]
    let state = try #require(try await store.handleControl(.getState) as? [String: Any])
    #expect(state["project"] as? String == "a")
    #expect(state["selection"] as? [String] == ["phone"])
    #expect(state["phase"] as? String == "stopped")
    #expect(state["error"] is NSNull)
    #expect((state["projects"] as? [[String: Any]])?.map { $0["id"] as? String } == ["a", "b", "off"])
    let frames = try #require(state["frames"] as? [[String: Any]])
    #expect(frames.map { $0["id"] as? String } == ["home", "phone"])
    #expect(frames[1]["x"] as? Double == 1600)
    #expect((state["viewport"] as? [String: Double])?["scale"] != nil)
}

@Test @MainActor func controlCommandsDriveTheStore() async throws {
    let store = controlledStore()
    _ = try await store.handleControl(.selectProject("b"))
    #expect(store.project?.id == "b")
    let token = store.viewportRequest.token
    _ = try await store.handleControl(.focusFrame("phone"))
    #expect(store.viewportRequest.token == token + 1)
    _ = try await store.handleControl(.zoom(2))
    #expect(store.zoomIndicator.viewport.scale == 2)
    _ = try await store.handleControl(.fitAll)
    #expect(store.viewportRequest.token == token + 3)
}

@Test @MainActor func controlCommandsReportChineseErrors() async {
    let store = controlledStore()
    #expect(await failure(store, .selectProject("zzz")) == "找不到作品：zzz")
    #expect(await failure(store, .selectProject("off")) == "作品已停用：off")
    #expect(await failure(store, .focusFrame("tv")) == "当前作品没有画框：tv")
    #expect(await failure(store, .frameSnapshot("tv")) == "当前作品没有画框：tv")
    #expect(await failure(store, .frameSnapshot("home")) == "画框尚未加载：home")
    #expect(await failure(store, .frameConsole("tv", limit: 50)) == "当前作品没有画框：tv")
    #expect(await failure(store, .frameConsole("home", limit: 50)) == "画框尚未加载：home")
    #expect(await failure(store, .frameRead("home")) == "画框尚未加载：home")
    #expect(await failure(store, .frameInteract("home", .click(selector: "button"))) == "画框尚未加载：home")
    #expect(await failure(store, .restartPreview) == "尚未打开项目目录")
}
