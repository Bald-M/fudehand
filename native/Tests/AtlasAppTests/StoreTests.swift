import Foundation
import Testing
@testable import AtlasApp
@testable import AtlasCore

private func sampleProject(id: String) -> Project {
    let preview = Preview(cwd: "examples/demo", command: ["pnpm", "dev"], port: 4401, baseUrl: "http://127.0.0.1:4401/")
    let frames = [
        Frame(id: "home", title: "首页", platform: "web", path: "/", width: 1440, height: 900, x: 0, y: 0),
        Frame(id: "phone", title: "手机", platform: "mobile", path: "/m", width: 390, height: 844, x: 1600, y: 0),
    ]
    return Project(id: id, title: "作品 \(id)", subtitle: "", description: "", author: "", sourceUrl: nil,
                   framework: "HTML", tags: [], enabled: true, layoutVersion: 1, preview: preview, frames: frames)
}

@Test @MainActor func fitAllIssuesAnimatedRequestWithNewToken() {
    let store = AtlasStore()
    store.select(sampleProject(id: "a"))
    let before = store.viewportRequest.token
    store.fitAll()
    #expect(store.viewportRequest.token == before + 1)
    #expect(store.viewportRequest.animated)
    #expect(store.viewportRequest.viewport == store.zoomIndicator.viewport)
}

@Test @MainActor func selectingProjectResetsSelectionAndBumpsPositionsToken() {
    let store = AtlasStore()
    store.select(sampleProject(id: "a"))
    store.selection = ["home"]
    let token = store.positionsToken
    store.select(sampleProject(id: "b"))
    #expect(store.selection.isEmpty)
    #expect(store.positionsToken == token + 1)
    #expect(!store.viewportRequest.animated)
}

@Test @MainActor func settledViewportIsSavedAndReflected() {
    let store = AtlasStore()
    store.select(sampleProject(id: "a"))
    let settled = Viewport(x: 40, y: -20, scale: 0.5)
    store.viewportSettled(settled)
    #expect(store.viewport == settled)
    #expect(store.zoomIndicator.scale == 0.5)
    #expect(store.zoomIndicator.viewport == settled)
}

@Test @MainActor func framesMovedMergesPositions() {
    let store = AtlasStore()
    store.select(sampleProject(id: "a"))
    let token = store.positionsToken
    store.framesMoved(["home": Point(x: 12, y: 34)])
    #expect(store.positions["home"] == Point(x: 12, y: 34))
    #expect(store.positions["phone"] == Point(x: 1600, y: 0))
    #expect(store.positionsToken == token)
}

@Test @MainActor func zoomToSelectionFallsBackToFitAll() {
    let store = AtlasStore()
    store.select(sampleProject(id: "a"))
    store.resize(CGSize(width: 1000, height: 700))
    store.selection = []
    store.zoomToSelection()
    let fitted = store.viewportRequest.viewport
    store.fitAll()
    #expect(store.viewportRequest.viewport == fitted)
    store.selection = ["phone"]
    store.zoomToSelection()
    #expect(store.viewportRequest.viewport != fitted)
    #expect(store.viewportRequest.animated)
}

@Test @MainActor func zoomIndicatorPublishesOnlyMeaningfulScaleChanges() {
    let indicator = ZoomIndicator()
    indicator.update(Viewport(x: 5, y: 5, scale: 1.001))
    #expect(indicator.scale == 1)
    #expect(indicator.viewport.scale == 1.001)
    indicator.update(Viewport(x: 5, y: 5, scale: 1.2))
    #expect(indicator.scale == 1.2)
}
