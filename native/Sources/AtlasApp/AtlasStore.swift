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
    let chat = ChatSession()
    @Published var showingChat = false
    /// 当前工作区置顶的作品 id。
    @Published private(set) var pinned: Set<String> = []
    @Published var projectOrder: ProjectOrder {
        didSet { defaults.set(projectOrder.rawValue, forKey: "native.projectOrder") }
    }
    /// 作品目录的最近修改时间；打开工作区后在后台扫描。
    @Published private(set) var modified: [String: Date] = [:]
    /// 侧栏缩略图，取自作品第一个画框的截图。
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    private var thumbnailCache: ThumbnailCache?
    private let thumbnailBase: URL
    /// 当前画布，供控制通道截取画框。
    weak var canvas: AtlasCanvasView?
    private let defaults: UserDefaults
    private var layouts: LayoutStore?
    private(set) var runtime: WorkspaceLocation?
    private var bootstrapped = false
    private var pendingSave: DispatchWorkItem?
    private var needsInitialFit = false
    private var hasMeasuredCanvas = false

    init(defaults: UserDefaults = .standard, thumbnailBase: URL = ThumbnailCache.defaultBase) {
        self.defaults = defaults
        self.thumbnailBase = thumbnailBase
        let stored = defaults.string(forKey: "native.theme") ?? "system"
        theme = ["light", "dark"].contains(stored) ? stored : "system"
        projectOrder = defaults.string(forKey: "native.projectOrder").flatMap(ProjectOrder.init(rawValue:)) ?? .catalog
    }

    /// 侧栏顺序：置顶在前，其余按当前排序方式。
    var orderedProjects: [Project] {
        SidebarOrdering.order(catalog?.projects ?? [], by: projectOrder, pinned: pinned, modified: modified)
    }

    private func pinnedKey(_ root: URL) -> String { "native.pinned.\(root.standardizedFileURL.path)" }

    func pinnedIDs(for root: URL) -> Set<String> { Set(defaults.stringArray(forKey: pinnedKey(root)) ?? []) }

    func togglePin(_ id: String) {
        guard let root else { return }
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        defaults.set(pinned.sorted(), forKey: pinnedKey(root))
    }

    /// 切换到 `url` 工作区的置顶与缩略图缓存。
    func loadWorkspaceState(_ url: URL) {
        root = url
        pinned = pinnedIDs(for: url)
        thumbnailCache = ThumbnailCache(directory: ThumbnailCache.directory(for: url, base: thumbnailBase))
        thumbnails = [:]
        modified = [:]
    }

    /// 读取已缓存的缩略图并在后台扫描各作品目录，不阻塞服务启动。
    private func loadSidebarMetadata(_ catalog: Catalog, root url: URL) {
        if let cache = thumbnailCache {
            for project in catalog.projects { if let image = cache.load(project.id) { thumbnails[project.id] = image } }
        }
        let directories = catalog.projects.map { ($0.id, url.appendingPathComponent($0.preview.cwd)) }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                var result: [String: Date] = [:]
                for (id, directory) in directories { result[id] = SidebarOrdering.lastModified(directory: directory) }
                return result
            }.value
            guard let self, self.root == url else { return }
            self.modified = result
        }
    }

    /// 画框加载完成；作品第一个画框的截图更新侧栏缩略图，失败时保留旧图。
    /// 加载完成时网页往往还没绘制（截出来是空白），所以稍等再截，期间画框重载或换了作品就放弃。
    func frameBecameReady(_ frameID: String) {
        guard let project, project.frames.first?.id == frameID, let cache = thumbnailCache,
              let view = canvas?.frames[frameID] else { return }
        let id = project.id
        Task { [weak view] in
            try? await Task.sleep(for: .seconds(2))
            guard let view, view.isReady, self.project?.id == id, self.canvas?.frames[frameID] === view,
                  let png = try? await view.snapshotPNG(), let image = try? cache.save(png, id: id) else { return }
            thumbnails[id] = image
        }
    }

    var colorScheme: ColorScheme? { theme == "dark" ? .dark : theme == "light" ? .light : nil }
    var ready: Bool { session.phase(for: project?.id) == .ready }

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
        panel.title = "选择 ui-atlas 项目目录"
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
        loadWorkspaceState(url)
        catalog = loaded
        loadSidebarMetadata(loaded, root: url)
        error = nil
        selection = []
        hasMeasuredCanvas = false
        defaults.set(url.path, forKey: "native.workspace")
        layouts = LayoutStore(defaults: defaults, namespace: "native.\(url.standardizedFileURL.path)")
        let recent = defaults.string(forKey: "native.recent.\(url.path)")
        let selected = loaded.projects.first { $0.enabled && $0.id == recent } ?? loaded.projects.first { $0.enabled }
        project = nil
        session.start(root: url, runtime: runtime)
        if let selected { select(selected) }
        else { positions = [:]; positionsToken += 1; viewport = Viewport(); zoomIndicator.update(viewport) }
    }

    func select(_ next: Project) {
        guard next.enabled else { return }
        // 再次选中当前作品时只补发启动请求，用于重试失败的案例服务。
        guard next.id != project?.id else { session.request(next.id); return }
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
        session.request(next.id)
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
        // Builds on the last requested or settled viewport, so presses during an animation stack.
        request(CanvasGeometry.zoomAt(viewport, point: Point(x: canvasSize.width / 2, y: canvasSize.height / 2), scale: scale),
                animated: true)
    }
    func zoomIn() { zoom(viewport.scale * 1.2) }
    func zoomOut() { zoom(viewport.scale / 1.2) }
    func reset() {
        guard let project else { return }
        pendingSave?.cancel()
        layouts?.clear(project: project)
        positions = Dictionary(uniqueKeysWithValues: project.frames.map { ($0.id, Point(x: $0.x, y: $0.y)) })
        positionsToken += 1
        selection = []
        fitAll(animated: false)
    }
    /// 启动器失败时整体重启；只是当前作品失败时只重试该作品。
    func retryPreview() {
        if case .failed = session.phase { restart() }
        else if let project { session.request(project.id) }
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
    func shutdown() async { saveNow(); await chat.shutdown(); await session.stop() }
}
