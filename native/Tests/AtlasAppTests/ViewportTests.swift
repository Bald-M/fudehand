import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

@Test @MainActor func resizingAfterSwitchingToANewProjectPreservesTheUsersViewport() {
    let preview = Preview(cwd: "examples/demo", command: ["pnpm", "dev"], port: 4401, baseUrl: "http://127.0.0.1:4401/")
    let frame = Frame(id: "home", title: "首页", platform: "web", path: "/", width: 1440, height: 900, x: 0, y: 0)
    let first = Project(id: "first", title: "作品一", subtitle: "", description: "", author: "", sourceUrl: nil,
                        framework: "HTML", tags: [], enabled: true, layoutVersion: 1, preview: preview, frames: [frame])
    var second = first
    second.id = "second"
    let store = AtlasStore()
    store.select(first)
    store.resize(CGSize(width: 1000, height: 700))
    store.select(second)
    store.zoom(1)
    let chosenViewport = store.viewport
    store.resize(CGSize(width: 900, height: 650))
    #expect(store.viewport == chosenViewport)
}
