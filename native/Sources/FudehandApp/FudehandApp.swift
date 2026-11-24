import AppKit
import Combine
import FudehandCore
import SwiftUI

@MainActor
final class FudehandAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: FudehandStore?
    private var quitting = false
    private var control: ControlServer?
    /// Open-file requests received during launch, before the window and the store are ready.
    private var pendingFiles: [URL] = []
    private var appearanceObserver: AnyCancellable?

    func attach(_ store: FudehandStore) {
        self.store = store
        // `$theme` publishes the new value before the property changes, so map the published value, not `store.theme`.
        appearanceObserver = store.$theme.sink { NSApplication.shared.appearance = FudehandStore.appearance(for: $0) }
        let files = pendingFiles
        pendingFiles = []
        // Only one document is edited at a time; when several are opened together, take the last one.
        files.last.map(store.openFromSystem)
    }

    /// Opens a .fudehand file double-clicked in Finder, dropped on the Dock icon, or chosen with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        // The extension is case-insensitive, matching how the system identifies file types.
        let files = urls.filter { $0.pathExtension.lowercased() == DesignDocument.fileExtension }
        guard let store else { pendingFiles += files; return }
        files.last.map(store.openFromSystem)
    }

    /// Starts the local control channel; a failure only affects external control, not use of the App.
    func startControl(_ store: FudehandStore) {
        guard control == nil else { return }
        let server = ControlServer { [weak store] command, caller in
            guard let store else { throw ControlCommandError("Fudehand is quitting") }
            return try await store.handleControl(command, caller: caller)
        }
        do { try server.start(); control = server }
        catch { FileHandle.standardError.write(Data("[fudehand] Control channel not started: \(error.localizedDescription)\n".utf8)) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A cold launch always shows the launch window first, on the current Space, and restores none of the windows open at
        // the last quit. Not keeping windows on quit is not enough: Quit and Keep Windows (⌥⌘Q), the system setting "Close
        // windows when quitting an application" turned off, and logging out with "Reopen windows" all keep them anyway, and the
        // restored editor and an empty Prototype window would come back on the Space each was on, bypassing the launch window.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false, "ApplePersistenceIgnoreState": true])
        // Before the first window shows; `attach` keeps it in step with the store from then on.
        NSApp.appearance = FudehandStore.appearance(for: UserDefaults.standard.string(forKey: "native.theme"))
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
        // Close the control channel first so no more commands are accepted while quitting.
        control?.stop()
        Task {
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct FudehandApp: App {
    @NSApplicationDelegateAdaptor(FudehandAppDelegate.self) private var delegate
    @StateObject private var store = FudehandStore(chatRoot: ChatSession.savedRoot, fontDirectory: FontLibrary.savedDirectory)

    static let launchWindowID = "launch"
    static let editorWindowID = "main"
    static let prototypeWindowID = "prototype"

    init() {
        // Before AppKit builds the menus: the App uses its own language setting, not the system's, and
        // system-provided menu items (About, Quit, Edit, Window) read `AppleLanguages` once at launch.
        let language = AppLanguage.saved(in: .standard)
        L10n.language = language
        UserDefaults.standard.set(language.preferredLanguages(system: AppLanguage.systemLanguages), forKey: "AppleLanguages")
    }

    var body: some Scene {
        // The first scene opens at launch: the launch window is shown first, and the editor window is entered only after New or Open.
        Window(L("Launch Window"), id: Self.launchWindowID) {
            LaunchView(store: store)
                // The scene's title is not refreshed while the window is open; this one is.
                .navigationTitle(L("Launch Window"))
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
                    Text(L("System menu items change after you restart Fudehand"))
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
                // Replacing this group also drops the system's Close item, so it is added back.
                Button(L("Close")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
                Button(L("Save")) { store.save() }.keyboardShortcut("s")
                Button(L("Save As…")) { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                ExportHTMLMenuItem(store: store, selection: store.layerSelection)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L("Undo")) { undoOrForward(#selector(UndoManager.undo)) { store.undo() } }.keyboardShortcut("z")
                Button(L("Redo")) { undoOrForward(#selector(UndoManager.redo)) { store.redo() } }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                DuplicateMenuItem(store: store, selection: store.layerSelection)
                Divider()
                Button(L("Find…")) { store.openFind() }.keyboardShortcut("f")
                FindStepMenuItems(store: store, find: store.find)
            }
            CommandMenu(L("Canvas")) {
                Button(L("Zoom In")) { store.zoomIn() }.keyboardShortcut("+")
                Button(L("Zoom Out")) { store.zoomOut() }.keyboardShortcut("-")
                Button(L("Actual Size")) { store.zoom(1) }.keyboardShortcut("1")
                Button(L("Fit All")) { store.fitAll() }.keyboardShortcut("0")
                Divider()
                Button(L("Insert Image…")) { store.insertImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button(L("Save Version Snapshot")) { store.saveVersionSnapshotOfSelection() }.keyboardShortcut("s", modifiers: [.command, .option])
                Button(L("Play Prototype")) { store.playPrototype() }.keyboardShortcut(.return, modifiers: [.command, .option])
                Button(L("Chat")) { store.showingInspector = true; store.inspectorTab = .chat }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        // Single window: one document is edited at a time; a WindowGroup would open another window for external events such as Finder opening a file.
        Window("Fudehand", id: Self.editorWindowID) {
            WorkspaceView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                // Closing the editor window returns to the launch window instead of quitting.
                .background(WindowCloseGuard { store.closeEditor(discarding: store.confirmDiscard) })
                .environment(\.locale, store.language.locale)
                .modifier(WindowActions(store: store, start: start))
        }
        .defaultSize(width: 1440, height: 940)

        Window(L("Prototype"), id: Self.prototypeWindowID) {
            PrototypeWindow(store: store)
                .environment(\.locale, store.language.locale)
        }
        .windowResizability(.contentSize)

        Window(L("MCP Connectors"), id: ConnectorsMenuItem.windowID) {
            ConnectorsView(model: store.connectors)
                .environment(\.locale, store.language.locale)
        }
        .windowResizability(.contentSize)
    }

    /// When the first window appears, reads the source location, opens the files received during launch, and starts the control channel.
    private func start() {
        guard delegate.store == nil else { return }
        store.bootstrap()
        delegate.attach(store)
        delegate.startControl(store)
    }

    /// When a text field has focus, undo goes to the text field; otherwise it undoes the design document.
    private func undoOrForward(_ selector: Selector, document: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            document()
        }
    }
}

/// "MCP Connectors…" in the application menu; getting openWindow inside commands requires a View.
private struct ConnectorsMenuItem: View {
    static let windowID = "connectors"
    /// Passed in so the item re-renders when the UI language changes.
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: Self.windowID) }
    }
}

/// Registers the window-switching action with the store: open the editor window, then close the launch window.
private struct WindowActions: ViewModifier {
    let store: FudehandStore
    let start: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            store.presentEditor = { [openWindow, dismissWindow] in
                // Opened in a later main-thread turn than the document load before it, so the two do not block at once (#252).
                DispatchQueue.main.async {
                    openWindow(id: FudehandApp.editorWindowID)
                    // Close the launch window only after the editor window appears, so the App does not quit during a moment with no windows.
                    DispatchQueue.main.async { dismissWindow(id: FudehandApp.launchWindowID) }
                }
            }
            store.presentPrototype = { [openWindow] in openWindow(id: FudehandApp.prototypeWindowID) }
            store.dismissPrototype = { [dismissWindow] in dismissWindow(id: FudehandApp.prototypeWindowID) }
            store.presentLaunch = { [openWindow] in openWindow(id: FudehandApp.launchWindowID) }
            // Closed after the launch window appears, as in presentEditor, so the App never has a moment with no windows.
            store.dismissEditor = { [dismissWindow] in DispatchQueue.main.async { dismissWindow(id: FudehandApp.editorWindowID) } }
            start()
        }
    }
}

/// File > Export as HTML…, available with exactly one layer selected. It observes the selection itself: the store publishes the
/// selection separately, so the menu would otherwise not see it change.
private struct ExportHTMLMenuItem: View {
    let store: FudehandStore
    @ObservedObject var selection: LayerSelection

    var body: some View {
        Button(L("Export as HTML…")) { store.exportHTMLWithPanel() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(selection.ids.count != 1)
    }
}

/// Edit › Duplicate (⌘D), available with layers selected; a focused text field leaves it alone. It observes the selection itself,
/// as Export as HTML… does.
private struct DuplicateMenuItem: View {
    let store: FudehandStore
    @ObservedObject var selection: LayerSelection

    var body: some View {
        Button(L("Duplicate")) {
            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
            store.duplicateSelection()
        }
        .keyboardShortcut("d")
        .disabled(selection.ids.isEmpty)
    }
}
