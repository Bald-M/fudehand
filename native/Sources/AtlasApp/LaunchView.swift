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
            Text("人和 Agent 共同编辑的设计文档").font(.callout).foregroundStyle(.secondary)
            Spacer().frame(height: 12)
            Button { store.newDocument() } label: {
                Label("新建设计文档", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n")
            Button { store.openDocument() } label: {
                Label("打开…", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .keyboardShortcut("o")
            Spacer()
        }
        .padding(24)
    }

    // MARK: 最近打开

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近打开").font(.headline)
                Spacer()
                if !entries.isEmpty {
                    Button("清除记录") { store.clearRecents() }.buttonStyle(.link)
                }
            }
            if entries.isEmpty {
                placeholder("还没有打开过的工程文件", systemImage: "clock")
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
            Text("模板").font(.headline)
            if templates.isEmpty {
                placeholder("暂无模板", systemImage: "square.grid.2x2")
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
                            .help("从“\(template.name)”新建未命名设计文档")
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

    private var url: URL { URL(fileURLWithPath: entry.path) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.available ? "doc" : "questionmark.folder")
                .font(.title2)
                .foregroundStyle(entry.available ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                Text(entry.available ? (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath : "文件已删除或移动")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(entry.openedAt, format: Self.dateFormat).font(.caption).foregroundStyle(.secondary)
            if !entry.available {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("从列表移除")
            }
        }
        .opacity(entry.available ? 1 : 0.6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(entry.path)
        .contextMenu {
            Button("打开", action: open).disabled(!entry.available)
            Button("从列表移除", action: remove)
        }
    }

    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "zh_CN"))
}

extension View {
    /// 在当前关键窗口中显示 store 的错误；启动窗口与编辑窗口同时打开时只弹出一次。
    func storeAlert(_ store: AtlasStore) -> some View { modifier(StoreAlert(store: store)) }
}

private struct StoreAlert: ViewModifier {
    @ObservedObject var store: AtlasStore
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.alert("操作失败", isPresented: Binding(get: { store.alert != nil && activeState == .key },
                                                  set: { if !$0 { store.alert = nil } })) {
            Button("好", role: .cancel) { store.alert = nil }
        } message: { Text(store.alert ?? "") }
    }
}
