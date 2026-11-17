import AppKit
import SwiftUI

@MainActor
final class AtlasAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AtlasStore?
    private var quitting = false
    private var control: ControlServer?

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
        WindowGroup("ui-atlas") {
            WorkspaceView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(store.colorScheme)
                .task { delegate.store = store; store.bootstrap(); delegate.startControl(store) }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(after: .appInfo) { ConnectorsMenuItem() }
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

        Window("MCP 连接器", id: ConnectorsMenuItem.windowID) {
            ConnectorsView(model: store.connectors)
                .preferredColorScheme(store.colorScheme)
        }
        .windowResizability(.contentSize)
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MCP 连接器…") { openWindow(id: Self.windowID) }
    }
}
