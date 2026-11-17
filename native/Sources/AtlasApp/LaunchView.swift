import AppKit
import AtlasCore
import SwiftUI

/// 启动窗口：新建、最近打开、模板。进入编辑后由 `AtlasStore.presentEditor` 关闭。
struct LaunchView: View {
    @ObservedObject var store: AtlasStore
    @State private var selection: String?
    /// 最近记录及文件是否存在；记录变化、窗口出现或任一窗口成为关键窗口时重新检查。
    @State private var entries: [RecentDocuments.Entry] = []
    private let templates = AtlasStore.bundledTemplates

    var body: some View {
        HStack(spacing: 0) {
            start
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .background(.background.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                recentSection
                templateSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .frame(width: 780, height: 500)
        .storeAlert(store)
        .onAppear(perform: refresh)
        .onReceive(store.$recents) { _ in DispatchQueue.main.async(execute: refresh) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
        let current = store.recentEntries
        if current != entries { entries = current }
    }

    // MARK: 新建

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("ui-atlas").font(.title.bold())
            Text(L("Design documents edited by people and Agents together")).font(.callout).foregroundStyle(.secondary)
            Spacer().frame(height: 12)
            Button { store.newDocument() } label: {
                Label(L("New Design Document"), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Button { store.openDocument() } label: {
                Label(L("Open…"), systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(24)
    }

    // MARK: 最近打开

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Recent")).font(.headline)
                Spacer()
                if !entries.isEmpty {
                    Button(L("Clear Recents")) { store.clearRecents() }.buttonStyle(.link)
                }
            }
            if entries.isEmpty {
                placeholder(L("No project files opened yet"), systemImage: "clock")
            } else {
                List(selection: $selection) {
                    ForEach(entries, id: \.path) { entry in
                        RecentRow(entry: entry,
                                  open: { store.openRecent(entry.path) },
                                  remove: { store.removeRecent(entry.path) })
                            .tag(entry.path)
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
                .onKeyPress(.return) {
                    guard let selection else { return .ignored }
                    store.openRecent(selection)
                    return .handled
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 模板

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Templates")).font(.headline)
            if templates.isEmpty {
                placeholder(L("No templates"), systemImage: "square.grid.2x2")
                    .frame(height: 96)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(templates) { template in
                            Button { store.newDocument(fromTemplate: template) } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "doc.richtext").font(.system(size: 28)).foregroundStyle(.secondary)
                                    Text(template.name).lineLimit(1)
                                }
                                .frame(width: 120, height: 88)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(L("Create an untitled design document from “%@”", template.name))
                        }
                    }
                }
                .frame(height: 96)
            }
        }
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2)
            Text(text)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

private struct RecentRow: View {
    let entry: RecentDocuments.Entry
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.locale) private var locale

    private var url: URL { URL(fileURLWithPath: entry.path) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.available ? "doc" : "questionmark.folder")
                .font(.title2)
                .foregroundStyle(entry.available ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                Text(entry.available ? (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath : L("File deleted or moved"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(entry.openedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)).font(.caption).foregroundStyle(.secondary)
            if !entry.available {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L("Remove from List"))
            }
        }
        .opacity(entry.available ? 1 : 0.6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(entry.path)
        .contextMenu {
            Button(L("Open"), action: open).disabled(!entry.available)
            Button(L("Remove from List"), action: remove)
        }
    }
}

extension View {
    /// 在当前关键窗口中显示 store 的错误；启动窗口与编辑窗口同时打开时只弹出一次。
    func storeAlert(_ store: AtlasStore) -> some View { modifier(StoreAlert(store: store)) }
}

private struct StoreAlert: ViewModifier {
    @ObservedObject var store: AtlasStore
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.alert(L("Operation Failed"), isPresented: Binding(get: { store.alert != nil && activeState == .key },
                                                  set: { if !$0 { store.alert = nil } })) {
            Button(L("OK"), role: .cancel) { store.alert = nil }
        } message: { Text(store.alert ?? "") }
    }
}
