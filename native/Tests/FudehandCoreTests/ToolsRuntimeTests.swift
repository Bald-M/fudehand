import Foundation
import Testing
import FudehandCore

@Test func nodeRuntimeParsesAndChecksTheVersion() {
    #expect(NodeRuntime.version("v22.12.0\n") == [22, 12, 0])
    #expect(NodeRuntime.version("v24.1.3") == [24, 1, 3])
    #expect(NodeRuntime.version("node: command not found") == nil)
    #expect(NodeRuntime.isSupported([22, 12, 0]))
    #expect(NodeRuntime.isSupported([23, 0, 0]))
    #expect(!NodeRuntime.isSupported([22, 11, 9]))
    #expect(!NodeRuntime.isSupported([20, 18, 0]))
}

@Test func nodeRuntimePicksTheFirstSupportedNode() {
    let old = (path: "/usr/local/bin/node", output: "v20.11.0" as String?)
    let new = (path: "/opt/homebrew/bin/node", output: "v22.14.0" as String?)
    let broken = (path: "/broken/node", output: nil as String?)
    #expect(NodeRuntime.pick([broken, old, new]) == .found(path: "/opt/homebrew/bin/node", version: "22.14.0"))
    // Only old ones: report the first so the window can say which one is too old.
    #expect(NodeRuntime.pick([broken, old]) == .tooOld(path: "/usr/local/bin/node", version: "20.11.0"))
    #expect(NodeRuntime.pick([broken]) == .missing)
    #expect(NodeRuntime.pick([]) == .missing)
}

@Test func toolSearchPathCoversCommonInstallLocationsWithoutBuildTimePath() {
    let path = ToolSearchPath.compose(recorded: nil, login: nil, inherited: "/usr/bin:/bin:/usr/sbin:/sbin", home: "/Users/me",
                                      nvmVersions: ["v20.1.0", "v22.12.0", "not-a-version", "v22.9.0"]).split(separator: ":").map(String.init)
    for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/Users/me/.local/bin", "/Users/me/.volta/bin", "/Users/me/.npm-global/bin"] {
        #expect(path.contains(directory), "\(directory)")
    }
    // nvm installs are tried newest first.
    let nvm = path.filter { $0.hasPrefix("/Users/me/.nvm/") }
    #expect(nvm == ["v22.12.0", "v22.9.0", "v20.1.0"].map { "/Users/me/.nvm/versions/node/\($0)/bin" })
    // No directory twice.
    #expect(Set(path).count == path.count)
}

@Test func toolSearchPathPutsRecordedThenLoginShellPathFirst() {
    let path = ToolSearchPath.compose(recorded: "/build/bin:/usr/bin", login: "/login/bin:/opt/homebrew/bin", inherited: "/usr/bin:/bin",
                                      home: "/Users/me", nvmVersions: [])
    #expect(path.hasPrefix("/build/bin:/usr/bin:/login/bin:/opt/homebrew/bin:/bin:"))
}

@Test func toolSearchPathReadsTheLoginShellOutput() {
    #expect(ToolSearchPath.loginPath(fromShellOutput: "Welcome!\n__FUDEHAND_PATH__/a/bin:/b/bin\n") == "/a/bin:/b/bin")
    #expect(ToolSearchPath.loginPath(fromShellOutput: "no marker") == nil)
    #expect(ToolSearchPath.loginPath(fromShellOutput: "__FUDEHAND_PATH__\n") == nil)
}

@Test func bundledToolsInstallOnceAndReplaceAnOlderBuild() throws {
    let files = FileManager.default
    let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: base) }
    let source = base.appendingPathComponent("App.app/Contents/Resources/Tools")
    let target = base.appendingPathComponent("Support/fudehand/tools")
    try files.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try Data("build-1".utf8).write(to: source.appendingPathComponent(BundledTools.buildMarker))
    try Data("one".utf8).write(to: source.appendingPathComponent("scripts/mcp-server.mjs"))

    try BundledTools.install(from: source, to: target)
    #expect(try String(contentsOf: target.appendingPathComponent("scripts/mcp-server.mjs"), encoding: .utf8) == "one")

    // Same build: the installed copy is left alone.
    try Data("local edit".utf8).write(to: target.appendingPathComponent("scripts/mcp-server.mjs"))
    try BundledTools.install(from: source, to: target)
    #expect(try String(contentsOf: target.appendingPathComponent("scripts/mcp-server.mjs"), encoding: .utf8) == "local edit")

    // A newer build replaces the whole directory, removing files it no longer ships.
    try Data("stale".utf8).write(to: target.appendingPathComponent("scripts/removed.mjs"))
    try Data("build-2".utf8).write(to: source.appendingPathComponent(BundledTools.buildMarker))
    try Data("two".utf8).write(to: source.appendingPathComponent("scripts/mcp-server.mjs"))
    try BundledTools.install(from: source, to: target)
    #expect(try String(contentsOf: target.appendingPathComponent("scripts/mcp-server.mjs"), encoding: .utf8) == "two")
    #expect(!files.fileExists(atPath: target.appendingPathComponent("scripts/removed.mjs").path))
    // No temporary copies are left beside it.
    #expect(try files.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["tools"])
}
