import Foundation
import Testing
import AtlasCore

@Test func layoutRestoresSavedPositionsAndFillsNewFramesFromTheCatalog() throws {
    let domain = "ui-atlas-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = LayoutStore(defaults: defaults, namespace: "test")
    let project = try sampleCatalog().projects[0]
    let saved = Layout(layoutVersion: 1, viewport: Viewport(x: -25, y: 80, scale: 0.5), positions: ["mobile": Point(x: 100, y: -200), "removed": Point(x: 3, y: 4)])
    store.save(saved, project: project)
    let restored = try #require(store.load(project: project))
    #expect(restored.viewport == saved.viewport)
    #expect(restored.positions == ["mobile": Point(x: 100, y: -200), "web": Point(x: 470, y: 0)])
    defaults.set(Data(#"{"layoutVersion":1,"viewport":{"x":0,"y":0,"scale":1},"positions":{"removed":"obsolete"}}"#.utf8), forKey: "test.layout.demo")
    #expect(store.load(project: project)?.positions == LayoutStore.defaultPositions(project))
    store.clear(project: project)
    #expect(store.load(project: project) == nil)
}

@Test func invalidOrOutdatedSavedLayoutsFallBackInsteadOfMovingTheCanvas() throws {
    let domain = "ui-atlas-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = LayoutStore(defaults: defaults, namespace: "test")
    let project = try sampleCatalog().projects[0]
    store.save(Layout(layoutVersion: 2, viewport: Viewport(), positions: [:]), project: project)
    #expect(store.load(project: project) == nil)
    store.save(Layout(layoutVersion: 1, viewport: Viewport(scale: 3), positions: [:]), project: project)
    #expect(store.load(project: project) == nil)
    defaults.set(Data(#"{"layoutVersion":1,"viewport":{"x":0,"y":0,"scale":1},"positions":{"mobile":{"x":true,"y":0}}}"#.utf8), forKey: "test.layout.demo")
    #expect(store.load(project: project) == nil)
    defaults.set(Data("not-json".utf8), forKey: "test.layout.demo")
    #expect(store.load(project: project) == nil)
}
