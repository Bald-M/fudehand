import AppKit
import SwiftUI

@MainActor
final class AtlasAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AtlasStore?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
                .task { delegate.store = store; await store.bootstrap() }
        }
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开项目目录…") { store.chooseWorkspace() }.keyboardShortcut("o")
            }
            CommandMenu("画布") {
                Button("放大") { store.zoom(store.zoomIndicator.viewport.scale * 1.2) }.keyboardShortcut("+")
                Button("缩小") { store.zoom(store.zoomIndicator.viewport.scale / 1.2) }.keyboardShortcut("-")
                Button("实际大小") { store.zoom(1) }.keyboardShortcut("1")
                Button("适应全部") { store.fitAll() }.keyboardShortcut("0")
                Divider()
                Button("重新加载案例") { store.reloadToken += 1 }.keyboardShortcut("r")
                Button("恢复默认布局") { store.reset() }
            }
        }
    }
}
