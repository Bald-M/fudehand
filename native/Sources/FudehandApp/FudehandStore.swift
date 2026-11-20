import AppKit
import FudehandCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The local source location that `pnpm build:native` writes into the app bundle; the chat panel uses it to find the harness and Node.
struct WorkspaceLocation: Decodable {
    let root: String
    let node: String?
    let path: String?
}

enum InspectorTab: String, CaseIterable { case design, chat }

/// App state: the sole owner of the design document and the undo history; the canvas, the panels, and the control channel all modify the document through it.
@MainActor
final class FudehandStore: ObservableObject {
    private(set) var editor = DesignEditor(measure: TextMetrics.measure)
    /// The document the panels display; not updated during a continuous gesture such as a drag, and updated once when it ends.
    @Published private(set) var document = DesignDocument()
    /// The selected layers, kept out of the store's published state: selecting in a large document then recomputes only the views
    /// that show the selection, not every view that observes the store (#142).
    let layerSelection = LayerSelection()
    var selection: Set<String> { layerSelection.ids }
    /// The layer under the pointer, shared by the canvas and the layers panel.
    let hover = LayerHover()
    @Published var tool: CanvasTool = .move
    @Published private(set) var fileURL: URL?
    @Published private(set) var savedRevision = 0
    /// The content at the last save (or at New/Open); returning to it by dragging back or undoing is not an edit.
    private var savedDocument = DesignDocument()
    /// The most recent viewport request; pushed directly to the canvas, bypassing SwiftUI, so the panels are not recomputed on every zoom.
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
            defaults.set(language.preferredLanguages(system: AppLanguage.systemLanguages), forKey: "AppleLanguages")
        }
    }
    let fontLibrary: FontLibrary
    /// The font families text layers can use: installed on the system or imported into the font library.
    @Published private(set) var fontFamilies: [FontFamily]
    let zoomIndicator = ZoomIndicator()
    let chat: ChatSession
    /// The source directory: the chat panel starts `scripts/agent-chat.mjs` from here.
    private(set) var toolsRoot: URL?
    private(set) var runtime: WorkspaceLocation?
    /// The model of the "MCP Connectors" window; the window may open before the main window, so the source location is read on demand.
    private(set) lazy var connectors: ConnectorsModel = {
        if toolsRoot == nil { bootstrap() }
        return ConnectorsModel(root: toolsRoot, runtime: runtime)
    }()
    private(set) var canvasSize = CGSize(width: 1000, height: 700)
    /// The most recent stable or requested viewport; the canvas owns the live viewport.
    private(set) var viewport = Viewport()
    weak var canvas: FudehandCanvasView?
    private var indexed: (revision: Int, index: DesignIndex)?
    /// The lookup index of the editor's current document, built once per document change and shared with the canvas.
    var index: DesignIndex {
        if let indexed, indexed.revision == editor.revision { return indexed.index }
        let index = DesignIndex(editor.document)
        indexed = (editor.revision, index)
        return index
    }
    private var inGesture = false
    /// The document was replaced while the editor window was not open: once the canvas appears, fit all at its actual size. The size changes a few times while the window opens,
    /// so this ends only after the size has been stable for a short while.
    private var fitWhenCanvasSized = false
    private var endFitWhenCanvasSized: DispatchWorkItem?
    private let defaults: UserDefaults
    /// The recently opened project files, shared by the launch window and the "Open Recent" menu.
    @Published private(set) var recents: RecentDocuments
    /// Shows the editor window and closes the launch window; registered by a view in a window after it gets the actions from the environment.
    var presentEditor: () -> Void = {}
    /// What the prototype window plays; set by Play Prototype.
    @Published private(set) var prototypeRequest: PrototypeRequest?
    /// Shows the prototype window; registered the same way as `presentEditor`.
    var presentPrototype: () -> Void = {}
    /// Shows the launch window, as Window › Launch Window does; registered the same way as `presentEditor`.
    var presentLaunch: () -> Void = {}
    /// The templates offered in the launch window.
    let templates: [Template]

    /// Where chat conversations are saved, one directory per design document; nil keeps them in memory only.
    private let chatRoot: URL?

    /// `fontDirectory` is where imported font files are kept; nil uses them in place, until the App quits.
    /// `templateDirectory` holds the templates; by default the ones bundled with the App.
    init(defaults: UserDefaults = .standard, chatRoot: URL? = nil, fontDirectory: URL? = nil,
         templateDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Templates")) {
        self.defaults = defaults
        templates = Self.templates(in: templateDirectory)
        SystemSymbols.install()
        fontLibrary = FontLibrary(directory: fontDirectory)
        fontFamilies = fontLibrary.families()
        self.chatRoot = chatRoot
        // The App starts on an untitled document. What an earlier one left behind was never saved with a file: drop it.
        let unsaved = chatRoot.map { ChatHistory.unsaved(root: $0) }
        unsaved?.remove()
        chat = ChatSession(history: unsaved)
        let stored = defaults.string(forKey: "native.theme") ?? "system"
        theme = ["light", "dark"].contains(stored) ? stored : "system"
        language = AppLanguage.saved(in: defaults)
        recents = RecentDocuments(data: defaults.data(forKey: Self.recentsKey))
    }

    var colorScheme: ColorScheme? { theme == "dark" ? .dark : theme == "light" ? .light : nil }
    var isDirty: Bool { editor.revision != savedRevision && editor.document != savedDocument }
    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? L("Untitled") }
    var canUndo: Bool { editor.canUndo }
    var canRedo: Bool { editor.canRedo }

    /// Reads the source location written at build time; starts no child process.
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

    /// Syncs the canvas and the panels after the document changes.
    private func changed() {
        let index = self.index
        canvas?.show(index)
        if !selection.allSatisfy(index.contains) { setSelection(selection.filter(index.contains)) }
        if !inGesture { document = index.document }
    }

    /// One undoable edit.
    func perform(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> Void) throws {
        try editor.perform(name, coalescing: coalescing, change)
        changed()
        // Edits received during a drag (such as Agent commands) are also shown in the panels immediately.
        if inGesture { document = editor.document }
    }

    /// An edit from a panel: shows the error on failure.
    func edit(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> Void) {
        do { try perform(name, coalescing: coalescing, change) } catch { alert = error.localizedDescription }
    }

    func updateNode(_ id: String, _ name: String, coalescing: String? = nil, _ change: @escaping (inout DesignNode) throws -> Void) {
        edit(name, coalescing: coalescing.map { "\(id).\($0)" }) { try $0.update(id, change) }
    }

    /// Undo and redo first end the drag in progress on the canvas, so later drags do not stop being recorded.
    func undo() { canvas?.releaseHeldInput(); if editor.undo() { changed() } }
    func redo() { canvas?.releaseHeldInput(); if editor.redo() { changed() } }

    func setSelection(_ ids: Set<String>) {
        guard ids != selection else { return }
        layerSelection.ids = ids
        canvas?.setSelection(ids)
    }

    /// Hovering a layer row outlines the layer on the canvas.
    func setHover(_ id: String?) {
        canvasHover(id)
        canvas?.showHover(id)
    }

    func attach(_ canvas: FudehandCanvasView) {
        self.canvas = canvas
        canvas.show(index)
        canvas.setSelection(selection)
    }

    /// The default appearance of a new layer.
    static func newNode(_ type: NodeType, id: String, rect: Rect, clicked: Bool) -> DesignNode {
        var node = DesignNode(id: id, type: type, x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        switch type {
        case .frame: node.fill = .white
        case .rectangle, .ellipse: node.fill = try? DesignColor(hex: "#D9D9D9")
        case .text: node.text = DesignText(content: L("Text"), fontSize: 16, autoResize: clicked ? .widthAndHeight : .height)
        case .image, .icon, .group: break
        }
        return node
    }

    /// Creates a layer at a canvas rectangle: when the start point falls inside a top-level frame, it is put into that frame.
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

    /// Inserts an image file: into the selected frame, otherwise at the center of the viewport.
    func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg]
        panel.title = L("Insert Image")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let size = DesignRenderer.imageSize(data) else { throw DesignError(L("Could not read image: %@", url.lastPathComponent)) }
            let width = Double(size.width), height = Double(size.height)
            let place = insertionPlacement(width: width, height: height)
            let id = DesignDocument.newID(existing: editor.document.allIDs())
            var node = DesignNode(id: id, type: .image, name: url.deletingPathExtension().lastPathComponent,
                                  x: place.x, y: place.y, width: width, height: height)
            node.image = DesignImage(data: data)
            try perform("Insert Image") { try $0.insert(node, parent: place.parent, index: nil) }
            setSelection([id])
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Inserts a 24 × 24 icon layer named after the icon, placed as Insert Image places an image, and selects it.
    func insertIcon(_ name: String) {
        let place = insertionPlacement(width: 24, height: 24)
        let id = DesignDocument.newID(existing: editor.document.allIDs())
        var node = DesignNode(id: id, type: .icon, name: IconLibrary.parse(name)?.name ?? name, x: place.x, y: place.y, width: 24, height: 24)
        node.icon = DesignIcon(name: name)
        do {
            try perform("Insert Icon") { try $0.insert(node, parent: place.parent, index: nil) }
            setSelection([id])
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Swaps an icon layer's icon, keeping its position, size, and color. A layer still named after the old icon is renamed
    /// after the new one; a name the person chose stays.
    func replaceIcon(_ id: String, with name: String) {
        updateNode(id, "Replace Icon") { node in
            let shortName = { (full: String) in IconLibrary.parse(full)?.name ?? full }
            if let old = node.icon?.name, node.name == shortName(old) { node.name = shortName(name) }
            node.icon?.name = name
        }
    }

    /// Where an inserted layer goes: at the origin of the one selected frame, otherwise centered in the viewport at the top level.
    private func insertionPlacement(width: Double, height: Double) -> (parent: String?, x: Double, y: Double) {
        if selection.count == 1, let id = selection.first, editor.document.node(id)?.type == .frame { return (id, 0, 0) }
        let center = CanvasGeometry.screenToWorld(Point(x: canvasSize.width / 2, y: canvasSize.height / 2), viewport: viewport)
        return (nil, center.x - width / 2, center.y - height / 2)
    }

    // MARK: Prototype

    /// The frame Play Prototype starts from: the top-level frame holding the selection, otherwise the first top-level frame.
    var prototypeStart: String? { Prototype.startFrame(in: editor.document, selection: selection) }

    func playPrototype() {
        guard let start = prototypeStart else { alert = L("Add a frame to play the prototype."); return }
        prototypeRequest = PrototypeRequest(start: start, token: (prototypeRequest?.token ?? 0) + 1)
        presentPrototype()
    }

    // MARK: Fonts

    /// Imports font files into the font library and returns their font families. Text layers already set to one of them are measured and drawn with it at once.
    @discardableResult
    func importFonts(_ urls: [URL]) throws -> [String] {
        // Files imported before one fails stay imported.
        defer {
            fontFamilies = fontLibrary.families()
            TextMetrics.resetCache()
            canvas?.fontsChanged()
            editor.applyLive { _ in }
            changed()
        }
        return try urls.flatMap(fontLibrary.importFont)
    }

    func importFontFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FontLibrary.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.title = L("Import Font")
        guard panel.runModal() == .OK else { return }
        do { try importFonts(panel.urls) } catch { alert = error.localizedDescription }
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

    /// Asks when there are unsaved changes: Save, Don't Save, or Cancel. Returns whether it is OK to continue.
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
        // Ask only after the file is chosen: the Agent may have modified the document while choosing.
        guard confirmDiscard() else { return }
        do { try open(url) } catch { alert = error.localizedDescription }
    }

    /// Reads and validates a project file; on failure the current document is unchanged.
    func open(_ url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DesignError(L("Could not read file: %@", url.lastPathComponent)) }
        replace(try DesignDocument.decode(data), url: url)
    }

    /// The conversations of the project file at `url`, or of the document without a file. The file is identified by its canonical
    /// path, so a symlink to it or another spelling of its name on a case-insensitive volume finds the same conversations.
    private func chatHistory(for url: URL?) -> ChatHistory? {
        guard let chatRoot else { return nil }
        guard let url else { return .unsaved(root: chatRoot) }
        let path = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? url.resolvingSymlinksInPath().path
        return .document(path: path, root: chatRoot)
    }

    /// Replaces the current document and enters the editor window; New, Open, templates, and Agent commands all go through here.
    func replace(_ next: DesignDocument, url: URL?) {
        canvas?.releaseHeldInput()
        editor.replace(next)
        inGesture = false
        chat.show(chatHistory(for: url), fresh: url == nil)
        fileURL = url
        savedRevision = editor.revision
        savedDocument = editor.document
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
        // Resolve symlinks, matching how openFromSystem identifies "the current file", so the same file does not appear twice.
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

    /// Opens a recent entry; when the file no longer exists, says so and offers to remove it from the list, leaving the current document unchanged.
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

    static func templates(in directory: URL?) -> [Template] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == DesignDocument.fileExtension }
            .map(Template.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// New from a template: produces an untitled document not associated with the template file, asking for a location on save.
    func newDocument(fromTemplate template: Template) {
        do { try newDocument(fromTemplate: template, discarding: confirmDiscard) } catch { alert = error.localizedDescription }
    }

    /// `discarding` decides whether unsaved changes may be dropped (the UI asks in an alert, the Agent passes `discard`).
    func newDocument(fromTemplate template: Template, discarding: () throws -> Bool) throws {
        guard try discarding() else { return }
        try openTemplate(template.url)
    }

    func openTemplate(_ url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DesignError(L("Could not read template: %@", url.lastPathComponent)) }
        replace(try DesignDocument.decode(data), url: nil)
    }

    /// Saves to the current file; asks for a location when never saved. Returns whether it was saved.
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
        if let history = chatHistory(for: url) { chat.rebind(to: history, moving: fileURL == nil) }
        fileURL = url
        savedRevision = editor.revision
        savedDocument = editor.document
        recordRecent(url)
    }

    /// Export as HTML for the selected layer: asks for an empty folder, then writes the page and its assets there.
    func exportHTMLWithPanel() {
        guard selection.count == 1, let id = selection.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = L("Export as HTML")
        panel.message = L("Choose an empty folder for the page and its images and icons.")
        panel.prompt = L("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportHTML(id, to: url) } catch { alert = error.localizedDescription }
    }

    /// Writes layer `id` as `index.html` and its assets into `directory`, which is created when missing and must otherwise be
    /// empty, so an export never replaces files. The document is not changed.
    @discardableResult
    func exportHTML(_ id: String, to directory: URL) throws -> DesignHTMLExport {
        guard let node = editor.document.node(id) else { throw DesignError("Layer not found: \(id)") }
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw HTMLExportError(reason: .notADirectory, path: directory.path) }
            let entries = (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
            guard entries.allSatisfy({ $0 == ".DS_Store" }) else { throw HTMLExportError(reason: .notEmpty, path: directory.path) }
        }
        var missingIcon: String?
        let result: DesignHTMLExport
        do {
            result = try DesignHTML.export(node) { name in
                let artwork = DesignHTML.bundledIcon(name) ?? MainActor.assumeIsolated { IconLayer.png(name) }.map { ($0, "png") }
                if artwork == nil { missingIcon = name }
                return artwork
            }
        } catch {
            if let missingIcon { throw HTMLExportError(reason: .missingIcon, path: missingIcon) }
            throw error
        }
        do {
            for (path, data) in result.files {
                let url = directory.appendingPathComponent(path)
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        } catch {
            throw HTMLExportError(reason: .unwritable, path: directory.path)
        }
        return result
    }

    /// The uniform type identifier of project files, exported in Info.plist (extension .fudehand, conforming to public.json).
    /// The exported type must be used: a dynamic type synthesized ad hoc from the extension differs from the type the system gives the file, and the open panel would treat the file as not selectable (#50).
    static let contentTypeIdentifier = "local.fudehand.design"

    static var contentType: UTType {
        UTType(exportedAs: contentTypeIdentifier, conformingTo: .json)
    }

    /// A project file passed by a Finder double-click or "Open With": asks first when there are unsaved changes, and shows the reason when it cannot be opened.
    func openFromSystem(_ url: URL) {
        do { try openFile(url, discarding: confirmDiscard) } catch { alert = error.localizedDescription }
    }

    /// Opens a project file from Finder or the recent files. The current file with no unsaved changes is only shown again; otherwise
    /// `discarding` decides whether unsaved changes may be dropped (the UI asks in an alert, the Agent passes `discard`).
    func openFile(_ url: URL, discarding: () throws -> Bool) throws {
        let current = url.resolvingSymlinksInPath() == fileURL?.resolvingSymlinksInPath()
        guard !current || isDirty else { recordRecent(url); presentEditor(); return }
        guard try discarding() else { return }
        try open(url)
    }

    func shutdown() async { await chat.shutdown() }
}

/// Kept out of the store's published state so pointer movement redraws only the layer rows that observe it.
final class LayerHover: ObservableObject {
    @Published var id: String?
}

/// Kept out of the store's published state so a selection change redraws only the layer rows and the inspector that observe it.
final class LayerSelection: ObservableObject {
    @Published fileprivate(set) var ids: Set<String> = []
}

// MARK: Canvas

extension FudehandStore: CanvasHost {
    func canvasSelect(_ ids: Set<String>) { if layerSelection.ids != ids { layerSelection.ids = ids } }

    func canvasHover(_ id: String?) { if hover.id != id { hover.id = id } }

    func canvasBeginGesture(_ name: String) {
        editor.beginGesture(name)
        inGesture = true
    }

    /// When the selection contains both a parent layer and its children, only the outermost layers are moved; the children move with their parent.
    private func outermost(_ ids: Set<String>, in index: DesignIndex) -> Set<String> {
        ids.filter { id in !index.ancestry(of: id).dropLast().contains(where: ids.contains) }
    }

    func canvasMove(_ origins: [String: Point]) {
        let index = self.index
        let roots = outermost(Set(origins.keys), in: index)
        editor.applyLive { document in
            // The roots are not nested in each other, so moving one leaves the others' indexed rectangles and paths valid.
            for (id, target) in origins where roots.contains(id) {
                guard let current = index.worldRect(id), let path = index.indexPath(of: id) else { continue }
                document.update(at: path) { $0.x += target.x - current.x; $0.y += target.y - current.y }
            }
        }
        changed()
    }

    func canvasResize(_ id: String, to rect: Rect) {
        let index = self.index
        editor.applyLive { document in
            guard let current = index.worldRect(id), let path = index.indexPath(of: id) else { return }
            document.update(at: path) { node in
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

    func canvasCreate(_ type: NodeType, in rect: Rect, clicked: Bool) {
        create(type, in: rect, clicked: clicked)
    }

    func canvasNudge(_ ids: Set<String>, by delta: Point) {
        let index = self.index
        let movable = outermost(ids, in: index).filter { id in
            guard let node = index.node(id), !node.locked, let parent = index.parentID(of: id) else { return false }
            return parent.flatMap { index.node($0)?.layout } == nil
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

/// Why Export as HTML wrote nothing; `localizedDescription` is for the UI, `english` for the control channel.
struct HTMLExportError: LocalizedError, Equatable {
    enum Reason { case notADirectory, notEmpty, unwritable, missingIcon }
    let reason: Reason
    /// The directory, or for `missingIcon` the icon name.
    let path: String

    var english: String {
        switch reason {
        case .notADirectory: return "Not a directory: \(path)"
        case .notEmpty: return "Directory is not empty: \(path)"
        case .unwritable: return "Could not write to \(path)"
        case .missingIcon: return "No artwork for icon \(path)"
        }
    }

    var errorDescription: String? {
        switch reason {
        case .notADirectory: return L("Not a folder: %@", path)
        case .notEmpty: return L("The folder is not empty: %@", path)
        case .unwritable: return L("Could not write to %@", path)
        case .missingIcon: return L("No artwork for icon %@", path)
        }
    }
}
