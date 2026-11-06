import AppKit
import AtlasCore
import Combine
import SwiftUI

@MainActor
final class AtlasStore: ObservableObject {
    @Published var catalog: Catalog?
    @Published var project: Project?
    /// The last settled viewport; the canvas owns the live one.
    private(set) var viewport = Viewport()
    @Published var positions: [String: Point] = [:]
    @Published var selection: Set<String> = []
    @Published var tool: CanvasTool = .move
    @Published private(set) var viewportRequest = ViewportRequest(viewport: Viewport(), animated: false, token: 0)
    @Published private(set) var positionsToken = 0
    let zoomIndicator = ZoomIndicator()
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
    private var hasMeasuredCanvas = false

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
        selection = []
        hasMeasuredCanvas = false
        defaults.set(url.path, forKey: "native.workspace")
        layouts = LayoutStore(defaults: defaults, namespace: "native.\(url.standardizedFileURL.path)")
        let recent = defaults.string(forKey: "native.recent.\(url.path)")
        let selected = loaded.projects.first { $0.enabled && $0.id == recent } ?? loaded.projects.first { $0.enabled }
        project = nil
        if let selected { select(selected) }
        else { positions = [:]; positionsToken += 1; viewport = Viewport(); zoomIndicator.update(viewport) }
        session.start(root: url, runtime: runtime)
    }

    func select(_ next: Project) {
        guard next.enabled, next.id != project?.id else { return }
        saveNow()
        selection = []
        project = next
        if let saved = layouts?.load(project: next) {
            positions = saved.positions
            positionsToken += 1
            request(saved.viewport, animated: false)
            needsInitialFit = false
        } else {
            positions = Dictionary(uniqueKeysWithValues: next.frames.map { ($0.id, Point(x: $0.x, y: $0.y)) })
            positionsToken += 1
            fitAll(animated: false)
            needsInitialFit = !hasMeasuredCanvas
        }
        if let root { defaults.set(next.id, forKey: "native.recent.\(root.path)") }
    }

    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        canvasSize = size
        hasMeasuredCanvas = true
        if needsInitialFit { needsInitialFit = false; fitAll(animated: false) }
    }

    /// The canvas reports its viewport once a pan, scroll or zoom has stopped.
    func viewportSettled(_ settled: Viewport) {
        viewport = settled
        zoomIndicator.update(settled)
        scheduleSave()
    }

    func framesMoved(_ moved: [String: Point]) {
        positions.merge(moved) { _, new in new }
        scheduleSave()
    }

    private func request(_ next: Viewport, animated: Bool) {
        viewport = next
        zoomIndicator.update(next)
        viewportRequest = ViewportRequest(viewport: next, animated: animated, token: viewportRequest.token + 1)
        scheduleSave()
    }

    private func rectangles(_ id: String? = nil) -> [Rect] {
        (project?.frames ?? []).filter { id == nil || $0.id == id }.map { frame in
            let point = positions[frame.id] ?? Point(x: frame.x, y: frame.y)
            return Rect(x: point.x, y: point.y, width: frame.width, height: frame.height + CanvasGeometry.headerHeight)
        }
    }

    private var canvasExtent: Size { Size(width: canvasSize.width, height: canvasSize.height) }

    func fitAll(animated: Bool = true) {
        request(CanvasGeometry.fitRects(rectangles(), size: canvasExtent, padding: 64), animated: animated)
    }
    func focusFrame(_ id: String) {
        request(CanvasGeometry.fitRects(rectangles(id), size: canvasExtent, padding: 40), animated: true)
    }
    func zoomToSelection() {
        guard !selection.isEmpty else { fitAll(); return }
        let rects = (project?.frames ?? []).filter { selection.contains($0.id) }.map { frame -> Rect in
            let point = positions[frame.id] ?? Point(x: frame.x, y: frame.y)
            return Rect(x: point.x, y: point.y, width: frame.width, height: frame.height + CanvasGeometry.headerHeight)
        }
        request(CanvasGeometry.fitRects(rects, size: canvasExtent, padding: 40), animated: true)
    }
    func zoom(_ scale: Double) {
        request(CanvasGeometry.zoomAt(zoomIndicator.viewport, point: Point(x: canvasSize.width / 2, y: canvasSize.height / 2), scale: scale),
                animated: true)
    }
    func reset() {
        guard let project else { return }
        pendingSave?.cancel()
        layouts?.clear(project: project)
        positions = Dictionary(uniqueKeysWithValues: project.frames.map { ($0.id, Point(x: $0.x, y: $0.y)) })
        positionsToken += 1
        selection = []
        fitAll(animated: false)
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
