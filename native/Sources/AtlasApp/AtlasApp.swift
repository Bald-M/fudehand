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
            guard let store else { throw ControlCommandError("界面图鉴正在退出") }
            return try await store.handleControl(command)
        }
        do { try server.start(); control = server }
        catch { FileHandle.standardError.write(Data("[界面图鉴] 控制通道未启动：\(error.localizedDescription)\n".utf8)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 先关闭控制通道，退出过程中不再接受命令。
        control?.stop()
        guard let store else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
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
        WindowGroup("界面图鉴") {
            WorkspaceView(store: store, session: store.session)
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(store.colorScheme)
                .task { delegate.store = store; delegate.startControl(store); await store.bootstrap() }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开项目目录…") { store.chooseWorkspace() }.keyboardShortcut("o")
            }
            CommandMenu("画布") {
                Button("放大") { store.zoomIn() }.keyboardShortcut("+")
                Button("缩小") { store.zoomOut() }.keyboardShortcut("-")
                Button("实际大小") { store.zoom(1) }.keyboardShortcut("1")
                Button("适应全部") { store.fitAll() }.keyboardShortcut("0")
                Divider()
                Button("重新加载案例") { store.reloadToken += 1 }.keyboardShortcut("r")
                Button("恢复默认布局") { store.reset() }
            }
        }
    }
}
