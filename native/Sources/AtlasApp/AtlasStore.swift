import AppKit
import AtlasCore
import Combine
import SwiftUI

@MainActor
final class AtlasStore: ObservableObject {
    @Published var catalog: Catalog?
    @Published var project: Project?
    @Published var viewport = Viewport()
    @Published var positions: [String: Point] = [:]
    @Published var interactingFrameID: String?
    @Published var reloadToken = 0
    @Published var canvasSize = CGSize(width: 1000, height: 700)
    @Published var root: URL?
    @Published var error: String?
    @Published var opening = false
    @Published var theme: String {
        didSet { defaults.set(theme, forKey: "native.theme") }
    }
    let session = PreviewSession()
    private let defaults = UserDefaults.standard
    private var layouts: LayoutStore?
    private var runtime: WorkspaceLocation?
    private var bootstrapped = false
    private var pendingSave: DispatchWorkItem?
    private var needsInitialFit = false

    init() {
        let stored = UserDefaults.standard.string(forKey: "native.theme") ?? "system"
        theme = ["light", "dark"].contains(stored) ? stored : "system"
    }

    var colorScheme: ColorScheme? { theme == "dark" ? .dark : theme == "light" ? .light : nil }
    var ready: Bool { session.phase == .ready }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if let url = Bundle.main.url(forResource: "workspace", withExtension: "json"),
           let data = try? Data(contentsOf: url) { runtime = try? JSONDecoder().decode(WorkspaceLocation.self, from: data) }
        let args = CommandLine.arguments
        let argumentRoot: String? = args.firstIndex(of: "--root").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let candidates = [argumentRoot, defaults.string(forKey: "native.workspace"), runtime?.root, FileManager.default.currentDirectoryPath].compactMap { $0 }
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("catalog.json").path) }) {
            await open(URL(fileURLWithPath: path))
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择界面图鉴项目目录"
        panel.message = "选择包含 catalog.json 和 examples 的仓库目录。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { Task { await open(url) } }
    }

    func open(_ url: URL) async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        // Validate before stopping the current workspace, so a wrong folder is recoverable.
        let loaded: Catalog
        do { loaded = try Catalog.load(from: url) }
        catch { self.error = "无法读取作品目录：\(error.localizedDescription)"; return }
        saveNow()
        await session.stop()
        root = url
        catalog = loaded
        error = nil
        interactingFrameID = nil
        defaults.set(url.path, forKey: "native.workspace")
        layouts = LayoutStore(defaults: defaults, namespace: "native.\(url.standardizedFileURL.path)")
        let recent = defaults.string(forKey: "native.recent.\(url.path)")
        let selected = loaded.projects.first { $0.enabled && $0.id == recent } ?? loaded.projects.first { $0.enabled }
        project = nil
        if let selected { select(selected) }
        else { positions = [:]; viewport = Viewport() }
        session.start(root: url, runtime: runtime)
    }

    func select(_ next: Project) {
        guard next.enabled, next.id != project?.id else { return }
        saveNow()
        interactingFrameID = nil
        project = next
        if let saved = layouts?.load(project: next) {
            positions = saved.positions
            viewport = saved.viewport
            needsInitialFit = false
        } else {
            positions = Dictionary(uniqueKeysWithValues: next.frames.map { ($0.id, Point(x: $0.x, y: $0.y)) })
            fitAll()
            needsInitialFit = true
        }
        if let root { defaults.set(next.id, forKey: "native.recent.\(root.path)") }
    }

    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        canvasSize = size
        if needsInitialFit { needsInitialFit = false; fitAll() }
    }

    func updateViewport(_ next: Viewport) { viewport = next; scheduleSave() }
    func moveFrame(_ id: String, to point: Point) { positions[id] = point; scheduleSave() }

    private func rectangles(_ id: String? = nil) -> [Rect] {
        (project?.frames ?? []).filter { id == nil || $0.id == id }.map { frame in
            let point = positions[frame.id] ?? Point(x: frame.x, y: frame.y)
            return Rect(x: point.x, y: point.y, width: frame.width, height: frame.height + CanvasGeometry.headerHeight)
        }
    }

    func fitAll() {
        updateViewport(CanvasGeometry.fitRects(rectangles(), size: Size(width: canvasSize.width, height: canvasSize.height), padding: 64))
    }
    func focusFrame(_ id: String) {
        interactingFrameID = nil
        updateViewport(CanvasGeometry.fitRects(rectangles(id), size: Size(width: canvasSize.width, height: canvasSize.height), padding: 40))
    }
    func zoom(_ scale: Double) {
        updateViewport(CanvasGeometry.zoomAt(viewport, point: Point(x: canvasSize.width / 2, y: canvasSize.height / 2), scale: scale))
    }
    func reset() {
        guard let project else { return }
        pendingSave?.cancel()
        layouts?.clear(project: project)
        positions = Dictionary(uniqueKeysWithValues: project.frames.map { ($0.id, Point(x: $0.x, y: $0.y)) })
        interactingFrameID = nil
        fitAll()
    }
    func restart() {
        guard let root, !opening else { return }
        Task { await open(root); reloadToken += 1 }
    }
    func saveNow() {
        pendingSave?.cancel()
        guard let project else { return }
        layouts?.save(AtlasCore.Layout(layoutVersion: project.layoutVersion, viewport: viewport, positions: positions), project: project)
    }
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
    func shutdown() async { saveNow(); await session.stop() }
}
