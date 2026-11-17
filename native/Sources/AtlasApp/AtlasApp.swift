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
        catch { FileHandle.standardError.write(Data("[ui-atlas] 控制通道未启动：\(error.localizedDescription)\n".utf8)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        guard store.confirmDiscard("退出") else { return .terminateCancel }
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

    var body: some Scene {
        // 单窗口：一次编辑一份文档；WindowGroup 会为 Finder 打开文件等外部事件再开新窗口。
        Window("ui-atlas", id: "main") {
            WorkspaceView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(store.colorScheme)
                .task { store.bootstrap(); delegate.attach(store); delegate.startControl(store) }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建") { store.newDocument() }.keyboardShortcut("n")
                Button("打开…") { store.openDocument() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { store.save() }.keyboardShortcut("s")
                Button("另存为…") { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { undoOrForward(#selector(UndoManager.undo)) { store.undo() } }.keyboardShortcut("z")
                Button("重做") { undoOrForward(#selector(UndoManager.redo)) { store.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("画布") {
                Button("放大") { store.zoomIn() }.keyboardShortcut("+")
                Button("缩小") { store.zoomOut() }.keyboardShortcut("-")
                Button("实际大小") { store.zoom(1) }.keyboardShortcut("1")
                Button("适应全部") { store.fitAll() }.keyboardShortcut("0")
                Divider()
                Button("插入图片…") { store.insertImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("对话") { store.showingInspector = true; store.inspectorTab = .chat }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
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
