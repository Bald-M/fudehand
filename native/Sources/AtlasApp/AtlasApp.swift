import AppKit
import AtlasCore
import SwiftUI

@MainActor
final class AtlasAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AtlasStore?
    private var quitting = false
    private var control: ControlServer?
    /// 启动过程中、窗口和 store 就绪前收到的打开文件请求。
    private var pendingFiles: [URL] = []

    func attach(_ store: AtlasStore) {
        self.store = store
        let files = pendingFiles
        pendingFiles = []
        // 一次只编辑一份文档，多选打开时取最后一个。
        files.last.map(store.openFromSystem)
    }

    /// Finder 双击、拖到 Dock 图标或“打开方式”打开 .uiatlas 文件。
    func application(_ application: NSApplication, open urls: [URL]) {
        // 扩展名不区分大小写，与系统识别文件类型的方式一致。
        let files = urls.filter { $0.pathExtension.lowercased() == DesignDocument.fileExtension }
        guard let store else { pendingFiles += files; return }
        files.last.map(store.openFromSystem)
    }

    /// 启动本地控制通道；失败只影响外部控制，不影响 App 使用。
    func startControl(_ store: AtlasStore) {
        guard control == nil else { return }
        let server = ControlServer { [weak store] command in
            guard let store else { throw ControlCommandError("ui-atlas 正在退出") }
            return try await store.handleControl(command)
        }
        do { try server.start(); control = server }
        catch { FileHandle.standardError.write(Data("[ui-atlas] Control channel not started: \(error.localizedDescription)\n".utf8)) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 冷启动总是先显示启动窗口，不恢复上次退出时打开的编辑窗口。
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        guard store.confirmDiscard() else { return .terminateCancel }
        quitting = true
        // 先关闭控制通道，退出过程中不再接受命令。
        control?.stop()
        Task {
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AtlasAppDelegate.self) private var delegate
    @StateObject private var store = AtlasStore()

    static let launchWindowID = "launch"
    static let editorWindowID = "main"

    init() {
        // Before AppKit builds the menus: the App uses its own language setting, not the system's, and
        // system-provided menu items (About, Quit, Edit, Window) read `AppleLanguages` once at launch.
        let language = AppLanguage.saved(in: .standard)
        L10n.language = language
        UserDefaults.standard.set(language.preferredLanguages(system: AppLanguage.systemLanguages), forKey: "AppleLanguages")
    }

    var body: some Scene {
        // 第一个场景在启动时打开：先显示启动窗口，新建或打开后才进入编辑窗口。
        Window(L("Launch Window"), id: Self.launchWindowID) {
            LaunchView(store: store)
                // The scene's title is not refreshed while the window is open; this one is.
                .navigationTitle(L("Launch Window"))
                .preferredColorScheme(store.colorScheme)
                .environment(\.locale, store.language.locale)
                .modifier(WindowActions(store: store, start: start))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) {
                ConnectorsMenuItem(title: L("MCP Connectors…"))
                Menu(L("Language")) {
                    Picker(L("Language"), selection: $store.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    Divider()
                    Text(L("System menu items change after you restart ui-atlas"))
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("New")) { store.newDocument() }.keyboardShortcut("n")
                Button(L("Open…")) { store.openDocument() }.keyboardShortcut("o")
                Menu(L("Open Recent")) {
                    ForEach(store.recentEntries, id: \.path) { entry in
                        Button(URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent) { store.openRecent(entry.path) }
                    }
                    if !store.recents.items.isEmpty { Divider() }
                    Button(L("Clear Recents")) { store.clearRecents() }.disabled(store.recents.items.isEmpty)
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("Save")) { store.save() }.keyboardShortcut("s")
                Button(L("Save As…")) { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L("Undo")) { undoOrForward(#selector(UndoManager.undo)) { store.undo() } }.keyboardShortcut("z")
                Button(L("Redo")) { undoOrForward(#selector(UndoManager.redo)) { store.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu(L("Canvas")) {
                Button(L("Zoom In")) { store.zoomIn() }.keyboardShortcut("+")
                Button(L("Zoom Out")) { store.zoomOut() }.keyboardShortcut("-")
                Button(L("Actual Size")) { store.zoom(1) }.keyboardShortcut("1")
                Button(L("Fit All")) { store.fitAll() }.keyboardShortcut("0")
                Divider()
                Button(L("Insert Image…")) { store.insertImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button(L("Chat")) { store.showingInspector = true; store.inspectorTab = .chat }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        // 单窗口：一次编辑一份文档；WindowGroup 会为 Finder 打开文件等外部事件再开新窗口。
        Window("ui-atlas", id: Self.editorWindowID) {
            WorkspaceView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(store.colorScheme)
                .environment(\.locale, store.language.locale)
                .modifier(WindowActions(store: store, start: start))
        }
        .defaultSize(width: 1440, height: 940)

        Window(L("MCP Connectors"), id: ConnectorsMenuItem.windowID) {
            ConnectorsView(model: store.connectors)
                .preferredColorScheme(store.colorScheme)
                .environment(\.locale, store.language.locale)
        }
        .windowResizability(.contentSize)
    }

    /// 第一个窗口出现时读取源码位置、打开启动过程中收到的文件并启动控制通道。
    private func start() {
        guard delegate.store == nil else { return }
        store.bootstrap()
        delegate.attach(store)
        delegate.startControl(store)
    }

    /// 文字输入框有焦点时撤销交给输入框，否则撤销设计文档。
    private func undoOrForward(_ selector: Selector, document: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            document()
        }
    }
}

/// 应用菜单中的“MCP 连接器…”；commands 里取得 openWindow 需要放在 View 中。
private struct ConnectorsMenuItem: View {
    static let windowID = "connectors"
    /// Passed in so the item re-renders when the UI language changes.
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: Self.windowID) }
    }
}

/// 向 store 登记切换窗口的动作：打开编辑窗口，再关闭启动窗口。
private struct WindowActions: ViewModifier {
    let store: AtlasStore
    let start: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            store.presentEditor = { [openWindow, dismissWindow] in
                openWindow(id: AtlasApp.editorWindowID)
                // 编辑窗口出现后再关闭启动窗口，避免一瞬间没有窗口而退出 App。
                DispatchQueue.main.async { dismissWindow(id: AtlasApp.launchWindowID) }
            }
            start()
        }
    }
}
