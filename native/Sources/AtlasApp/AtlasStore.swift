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
    let zoomIndicator = ZoomIndicator()
    let chat = ChatSession()
    /// 源码目录：对话面板从这里启动 `scripts/agent-chat.mjs`。
    private(set) var toolsRoot: URL?
    private(set) var runtime: WorkspaceLocation?
    private(set) var canvasSize = CGSize(width: 1000, height: 700)
    /// 最近一次稳定或请求的视口；画布持有实时视口。
    private(set) var viewport = Viewport()
    weak var canvas: AtlasCanvasView?
    private var inGesture = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: "native.theme") ?? "system"
        theme = ["light", "dark"].contains(stored) ? stored : "system"
    }

    var colorScheme: ColorScheme? { theme == "dark" ? .dark : theme == "light" ? .light : nil }
    var isDirty: Bool { editor.revision != savedRevision }
    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "未命名" }
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
        case .text: node.text = DesignText(content: "文字", fontSize: 16, autoResize: clicked ? .widthAndHeight : .height)
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
        edit("新建\(type.title)") { try $0.insert(node, parent: parent?.id, index: nil) }
        if editor.document.node(id) != nil { setSelection([id]) }
        tool = .move
    }

    /// 插入图片文件：放进选中的画框，否则放在视口中央。
    func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.title = "插入图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let image = DesignRenderer.cgImage(data) else { throw DesignError("无法读取图片：\(url.lastPathComponent)") }
            let parent = selection.count == 1 ? selection.first.flatMap { id in editor.document.node(id)?.type == .frame ? id : nil } : nil
            let width = Double(image.width) / 2, height = Double(image.height) / 2
            let center = CanvasGeometry.screenToWorld(Point(x: canvasSize.width / 2, y: canvasSize.height / 2), viewport: viewport)
            let id = DesignDocument.newID(existing: editor.document.allIDs())
            var node = DesignNode(id: id, type: .image, name: url.deletingPathExtension().lastPathComponent,
                                  x: parent == nil ? center.x - width / 2 : 0, y: parent == nil ? center.y - height / 2 : 0,
                                  width: width, height: height)
            node.image = DesignImage(data: data)
            try perform("插入图片") { try $0.insert(node, parent: parent, index: nil) }
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
    func confirmDiscard(_ action: String) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "要保存对“\(title)”的修改吗？"
        alert.informativeText = "\(action)前不保存，修改将会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func newDocument() {
        guard confirmDiscard("新建") else { return }
        replace(DesignDocument(), url: nil)
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.title = "打开工程文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 选好文件后再询问：选择期间 Agent 可能修改了文档。
        guard confirmDiscard("打开其他文件") else { return }
        do { try open(url) } catch { alert = error.localizedDescription }
    }

    /// 读取并校验工程文件；失败时当前文档不变。
    func open(_ url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DesignError("无法读取文件：\(url.lastPathComponent)") }
        replace(try DesignDocument.decode(data), url: url)
    }

    func replace(_ next: DesignDocument, url: URL?) {
        canvas?.releaseHeldInput()
        editor.replace(next)
        inGesture = false
        fileURL = url
        savedRevision = editor.revision
        setSelection([])
        changed()
        fitAll(animated: false)
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
    }

    static var contentType: UTType {
        UTType(filenameExtension: DesignDocument.fileExtension, conformingTo: .json) ?? .json
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
        edit("移动图层") { document in
            for id in movable { try document.update(id) { $0.x += delta.x; $0.y += delta.y } }
        }
    }

    func canvasDelete(_ ids: Set<String>) {
        edit("删除图层") { try $0.delete(ids) }
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
    }
}
