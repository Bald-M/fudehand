import AppKit
import AtlasCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// `pnpm build:native` 写入 App 包的本机源码位置；对话面板据此找到 harness 与 Node。
struct WorkspaceLocation: Decodable {
    let root: String
    let node: String?
    let path: String?
}

enum InspectorTab: String, CaseIterable { case design, chat }

/// App 状态：唯一持有设计文档与撤销历史；画布、面板与控制通道都经它修改文档。
@MainActor
final class AtlasStore: ObservableObject {
    private(set) var editor = DesignEditor(measure: TextMetrics.measure)
    /// 面板显示用的文档；拖动等连续操作期间不更新，结束时一次更新。
    @Published private(set) var document = DesignDocument()
    @Published private(set) var selection: Set<String> = []
    @Published var tool: CanvasTool = .move
    @Published private(set) var fileURL: URL?
    @Published private(set) var savedRevision = 0
    /// 最近一次视口请求；直接推给画布，不经 SwiftUI，避免每次缩放都重新计算面板。
    private(set) var viewportRequest = ViewportRequest(viewport: Viewport(), animated: false, token: 0)
    @Published var inspectorTab: InspectorTab = .design
    @Published var showingInspector = true
    @Published var alert: String?
    @Published var theme: String {
        didSet { defaults.set(theme, forKey: "native.theme") }
    }
    /// UI language. Views that observe the store re-render on change; the rest read `\.locale`, which each window sets from here.
    @Published var language: AppLanguage {
        didSet {
            L10n.language = language
            language.save(in: defaults)
            // System-provided menu items follow this at the next launch.
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
    let zoomIndicator = ZoomIndicator()
    let chat = ChatSession()
    /// 源码目录：对话面板从这里启动 `scripts/agent-chat.mjs`。
    private(set) var toolsRoot: URL?
    private(set) var runtime: WorkspaceLocation?
    /// “MCP 连接器”窗口的模型；窗口可能先于主窗口打开，所以按需读取源码位置。
    private(set) lazy var connectors: ConnectorsModel = {
        if toolsRoot == nil { bootstrap() }
        return ConnectorsModel(root: toolsRoot, runtime: runtime)
    }()
    private(set) var canvasSize = CGSize(width: 1000, height: 700)
    /// 最近一次稳定或请求的视口；画布持有实时视口。
    private(set) var viewport = Viewport()
    weak var canvas: AtlasCanvasView?
    private var inGesture = false
    /// 编辑窗口未打开时替换了文档：画布出现后按实际尺寸适应全部。窗口打开过程中尺寸会变化几次，
    /// 尺寸稳定一小段时间后才结束。
    private var fitWhenCanvasSized = false
    private var endFitWhenCanvasSized: DispatchWorkItem?
    private let defaults: UserDefaults
    /// 最近打开的工程文件，启动窗口与“打开最近”菜单共用。
    @Published private(set) var recents: RecentDocuments
    /// 显示编辑窗口并关闭启动窗口；由窗口中的视图从环境取得动作后登记。
    var presentEditor: () -> Void = {}

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: "native.theme") ?? "system"
        theme = ["light", "dark"].contains(stored) ? stored : "system"
        language = AppLanguage.saved(in: defaults)
        recents = RecentDocuments(data: defaults.data(forKey: Self.recentsKey))
    }

    var colorScheme: ColorScheme? { theme == "dark" ? .dark : theme == "light" ? .light : nil }
    var isDirty: Bool { editor.revision != savedRevision }
    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? L("Untitled") }
    var canUndo: Bool { editor.canUndo }
    var canRedo: Bool { editor.canRedo }

    /// 读取构建时写入的源码位置；不启动任何子进程。
    func bootstrap() {
        if let url = Bundle.main.url(forResource: "workspace", withExtension: "json"),
           let data = try? Data(contentsOf: url) { runtime = try? JSONDecoder().decode(WorkspaceLocation.self, from: data) }
        let args = CommandLine.arguments
        let argumentRoot = args.firstIndex(of: "--root").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let candidates = [argumentRoot, runtime?.root, FileManager.default.currentDirectoryPath].compactMap { $0 }
        toolsRoot = candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scripts/agent-chat.mjs").path) }
    }

    // MARK: Document changes

    /// 文档变化后同步画布与面板。
    private func changed() {
        let current = editor.document
        canvas?.show(current)
        let ids = current.allIDs()
        if !selection.isSubset(of: ids) { setSelection(selection.intersection(ids)) }
        if !inGesture { document = current }
    }

    /// 一次可撤销的修改。
    func perform(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> Void) throws {
        try editor.perform(name, coalescing: coalescing, change)
        changed()
        // 拖动中收到的修改（如 Agent 命令）也立即显示在面板中。
        if inGesture { document = editor.document }
    }

    /// 面板里的修改：失败时显示错误。
    func edit(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> Void) {
        do { try perform(name, coalescing: coalescing, change) } catch { alert = error.localizedDescription }
    }

    func updateNode(_ id: String, _ name: String, coalescing: String? = nil, _ change: @escaping (inout DesignNode) throws -> Void) {
        edit(name, coalescing: coalescing.map { "\(id).\($0)" }) { try $0.update(id, change) }
    }

    /// 撤销、重做先结束画布上进行中的拖动，避免之后的拖动不再记录。
    func undo() { canvas?.releaseHeldInput(); if editor.undo() { changed() } }
    func redo() { canvas?.releaseHeldInput(); if editor.redo() { changed() } }

    func setSelection(_ ids: Set<String>) {
        guard ids != selection else { return }
        selection = ids
        canvas?.setSelection(ids)
    }

    func attach(_ canvas: AtlasCanvasView) {
        self.canvas = canvas
        canvas.show(editor.document)
        canvas.setSelection(selection)
    }

    /// 新建图层的默认外观。
    static func newNode(_ type: NodeType, id: String, rect: Rect, clicked: Bool) -> DesignNode {
        var node = DesignNode(id: id, type: type, x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        switch type {
        case .frame: node.fill = .white
        case .rectangle, .ellipse: node.fill = try? DesignColor(hex: "#D9D9D9")
        case .text: node.text = DesignText(content: L("Text"), fontSize: 16, autoResize: clicked ? .widthAndHeight : .height)
        case .image, .group: break
        }
        return node
    }

    /// 在画布矩形处新建图层：起点落在某个顶层画框内时放进该画框。
    func create(_ type: NodeType, in rect: Rect, clicked: Bool) {
        let point = Point(x: rect.x, y: rect.y)
        let parent = type == .frame ? nil : editor.document.nodes.last {
            $0.type == .frame && $0.visible && !$0.locked && $0.frame.contains(point)
        }
        let origin = parent.map { Point(x: $0.x, y: $0.y) } ?? Point(x: 0, y: 0)
        let id = DesignDocument.newID(existing: editor.document.allIDs())
        let node = Self.newNode(type, id: id, rect: Rect(x: rect.x - origin.x, y: rect.y - origin.y, width: rect.width, height: rect.height),
                                clicked: clicked)
        edit("Create \(type.rawValue.capitalized)") { try $0.insert(node, parent: parent?.id, index: nil) }
        if editor.document.node(id) != nil { setSelection([id]) }
        tool = .move
    }

    /// 插入图片文件：放进选中的画框，否则放在视口中央。
    func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.title = L("Insert Image")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let image = DesignRenderer.cgImage(data) else { throw DesignError(L("Cannot read image: %@", url.lastPathComponent)) }
            let parent = selection.count == 1 ? selection.first.flatMap { id in editor.document.node(id)?.type == .frame ? id : nil } : nil
            let width = Double(image.width) / 2, height = Double(image.height) / 2
            let center = CanvasGeometry.screenToWorld(Point(x: canvasSize.width / 2, y: canvasSize.height / 2), viewport: viewport)
            let id = DesignDocument.newID(existing: editor.document.allIDs())
            var node = DesignNode(id: id, type: .image, name: url.deletingPathExtension().lastPathComponent,
                                  x: parent == nil ? center.x - width / 2 : 0, y: parent == nil ? center.y - height / 2 : 0,
                                  width: width, height: height)
            node.image = DesignImage(data: data)
            try perform("Insert Image") { try $0.insert(node, parent: parent, index: nil) }
            setSelection([id])
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: Viewport

    private func request(_ next: Viewport, animated: Bool) {
        viewport = next
        zoomIndicator.update(next)
        viewportRequest = ViewportRequest(viewport: next, animated: animated, token: viewportRequest.token + 1)
        canvas?.update(viewportRequest: viewportRequest, tool: tool)
    }

    private var canvasExtent: Size { Size(width: canvasSize.width, height: canvasSize.height) }

    func fitAll(animated: Bool = true) {
        let rects = editor.document.nodes.filter(\.visible).map(\.frame)
        request(rects.isEmpty ? Viewport() : CanvasGeometry.fitRects(rects, size: canvasExtent, padding: 64), animated: animated)
    }

    func focus(_ id: String) {
        guard let rect = editor.document.worldRect(id) else { return }
        request(CanvasGeometry.fitRects([rect], size: canvasExtent, padding: 40), animated: true)
    }

    func zoomToSelection() {
        let rects = selection.compactMap { editor.document.worldRect($0) }
        guard !rects.isEmpty else { fitAll(); return }
        request(CanvasGeometry.fitRects(rects, size: canvasExtent, padding: 40), animated: true)
    }

    func zoom(_ scale: Double) {
        request(CanvasGeometry.zoomAt(viewport, point: Point(x: canvasSize.width / 2, y: canvasSize.height / 2), scale: scale), animated: true)
    }
    func zoomIn() { zoom(viewport.scale * 1.2) }
    func zoomOut() { zoom(viewport.scale / 1.2) }

    // MARK: Files

    /// 有未保存修改时询问：保存、不保存或取消。返回是否可以继续。
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("Do you want to save the changes made to “%@”?", title)
        alert.informativeText = L("Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don’t Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func newDocument() {
        guard confirmDiscard() else { return }
        replace(DesignDocument(), url: nil)
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.title = L("Open Project File")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 选好文件后再询问：选择期间 Agent 可能修改了文档。
        guard confirmDiscard() else { return }
        do { try open(url) } catch { alert = error.localizedDescription }
    }

    /// 读取并校验工程文件；失败时当前文档不变。
    func open(_ url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DesignError(L("Cannot read file: %@", url.lastPathComponent)) }
        replace(try DesignDocument.decode(data), url: url)
    }

    /// 替换当前文档并进入编辑窗口；新建、打开、模板与 Agent 命令都经过这里。
    func replace(_ next: DesignDocument, url: URL?) {
        canvas?.releaseHeldInput()
        editor.replace(next)
        inGesture = false
        fileURL = url
        savedRevision = editor.revision
        setSelection([])
        changed()
        fitAll(animated: false)
        if canvas == nil { fitWhenCanvasSized = true }
        if let url { recordRecent(url) }
        presentEditor()
    }

    // MARK: Recent documents

    private static let recentsKey = "native.recentDocuments"

    private func recordRecent(_ url: URL) {
        // 解析符号链接，与 openFromSystem 判断“当前文件”的方式一致，避免同一文件出现两条。
        updateRecents { $0.record(url.resolvingSymlinksInPath().path, at: Date()) }
    }

    func removeRecent(_ path: String) { updateRecents { $0.remove(path) } }
    func clearRecents() { updateRecents { $0.clear() } }

    private func updateRecents(_ change: (inout RecentDocuments) -> Void) {
        change(&recents)
        defaults.set(recents.encoded(), forKey: Self.recentsKey)
    }

    var recentEntries: [RecentDocuments.Entry] {
        recents.entries { FileManager.default.fileExists(atPath: $0) }
    }

    /// 打开一条最近记录；文件已不存在时提示并可从列表移除，当前文档不变。
    func openRecent(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            let alert = NSAlert()
            alert.messageText = L("“%@” cannot be found", URL(fileURLWithPath: path).lastPathComponent)
            alert.informativeText = L("The file may have been deleted or moved.")
            alert.addButton(withTitle: L("Remove from List"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { removeRecent(path) }
            return
        }
        openFromSystem(URL(fileURLWithPath: path))
    }

    // MARK: Templates

    struct Template: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    /// App 自带的模板：构建时复制到 `Contents/Resources/Templates/` 的 `.uiatlas` 文件。
    static var bundledTemplates: [Template] {
        templates(in: Bundle.main.resourceURL?.appendingPathComponent("Templates"))
    }

    static func templates(in directory: URL?) -> [Template] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == DesignDocument.fileExtension }
            .map(Template.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 从模板新建：得到未命名文档，不关联模板文件，保存时询问位置。
    func newDocument(fromTemplate template: Template) {
        guard confirmDiscard() else { return }
        do { try openTemplate(template.url) } catch { alert = error.localizedDescription }
    }

    func openTemplate(_ url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DesignError(L("Cannot read template: %@", url.lastPathComponent)) }
        replace(try DesignDocument.decode(data), url: nil)
    }

    /// 保存到当前文件；未保存过时询问位置。返回是否已保存。
    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return saveAs() }
        do { try write(to: fileURL); return true } catch { alert = error.localizedDescription; return false }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.nameFieldStringValue = "\(title).\(DesignDocument.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try write(to: url); return true } catch { alert = error.localizedDescription; return false }
    }

    func write(to url: URL) throws {
        try editor.document.encoded().write(to: url, options: .atomic)
        fileURL = url
        savedRevision = editor.revision
        recordRecent(url)
    }

    /// 工程文件的统一类型标识，在 Info.plist 中导出（扩展名 .uiatlas，符合 public.json）。
    /// 必须用已导出的类型：按扩展名临时合成的动态类型与系统给文件的类型不同，打开面板会把文件判为不可选（#50）。
    static let contentTypeIdentifier = "local.ui-atlas.design"

    static var contentType: UTType {
        UTType(exportedAs: contentTypeIdentifier, conformingTo: .json)
    }

    /// Finder 双击或“打开方式”传来的工程文件：有未保存修改时先询问，打不开时显示原因。
    func openFromSystem(_ url: URL) {
        let current = url.resolvingSymlinksInPath() == fileURL?.resolvingSymlinksInPath()
        guard !current || isDirty else { recordRecent(url); presentEditor(); return }
        guard confirmDiscard() else { return }
        do { try open(url) } catch { alert = error.localizedDescription }
    }

    func shutdown() async { await chat.shutdown() }
}

// MARK: Canvas

extension AtlasStore: CanvasHost {
    func canvasSelect(_ ids: Set<String>) { selection = ids }

    func canvasBeginGesture(_ name: String) {
        editor.beginGesture(name)
        inGesture = true
    }

    /// 选择中同时有父图层与其子图层时，只移动最外层的图层，子图层随父图层移动。
    private func outermost(_ ids: Set<String>, in document: DesignDocument) -> Set<String> {
        ids.filter { id in !document.ancestry(of: id).dropLast().contains(where: ids.contains) }
    }

    func canvasMove(_ origins: [String: Point]) {
        let roots = outermost(Set(origins.keys), in: editor.document)
        editor.applyLive { document in
            for (id, target) in origins where roots.contains(id) {
                guard let current = document.worldRect(id) else { continue }
                try? document.update(id) { $0.x += target.x - current.x; $0.y += target.y - current.y }
            }
        }
        changed()
    }

    func canvasResize(_ id: String, to rect: Rect) {
        editor.applyLive { document in
            guard let current = document.worldRect(id) else { return }
            try? document.update(id) { node in
                let widthChanged = rect.width != current.width, heightChanged = rect.height != current.height
                node.x += rect.x - current.x
                node.y += rect.y - current.y
                node.width = rect.width
                node.height = rect.height
                if widthChanged { node.sizing.horizontal = .fixed }
                if heightChanged { node.sizing.vertical = .fixed }
                if node.text != nil {
                    if heightChanged { node.text?.autoResize = .none }
                    else if widthChanged, node.text?.autoResize == .widthAndHeight { node.text?.autoResize = .height }
                }
            }
        }
        changed()
    }

    func canvasEndGesture() {
        editor.endGesture()
        inGesture = false
        changed()
    }

    func canvasCreate(_ type: NodeType, in rect: Rect) {
        let clicked = rect.width == CanvasInteraction.defaultSize && rect.height == CanvasInteraction.defaultSize
        create(type, in: rect, clicked: clicked)
    }

    func canvasNudge(_ ids: Set<String>, by delta: Point) {
        let document = editor.document
        let movable = outermost(ids, in: document).filter { id in
            guard let node = document.node(id), !node.locked, let parent = document.parentID(of: id) else { return false }
            return parent.flatMap { document.node($0)?.layout } == nil
        }
        guard !movable.isEmpty else { return }
        edit("Move Layers") { document in
            for id in movable { try document.update(id) { $0.x += delta.x; $0.y += delta.y } }
        }
    }

    func canvasDelete(_ ids: Set<String>) {
        edit("Delete Layers") { try $0.delete(ids) }
        setSelection([])
    }

    func canvasToolChanged(_ tool: CanvasTool) { self.tool = tool }

    func canvasCommand(_ command: CanvasCommand) {
        switch command {
        case .fitAll: fitAll()
        case .zoomToSelection: zoomToSelection()
        case .actualSize: zoom(1)
        }
    }

    func canvasFocus(_ id: String) { focus(id) }

    func canvasViewportSettled(_ settled: Viewport) {
        viewport = settled
        zoomIndicator.update(settled)
    }

    func canvasSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        canvasSize = size
        if fitWhenCanvasSized {
            fitAll(animated: false)
            endFitWhenCanvasSized?.cancel()
            let end = DispatchWorkItem { [weak self] in self?.fitWhenCanvasSized = false }
            endFitWhenCanvasSized = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: end)
        }
    }
}
