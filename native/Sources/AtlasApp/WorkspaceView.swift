import AppKit
import AtlasCore
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: AtlasStore
    @ObservedObject var session: PreviewSession
    @State private var search = ""

    private var projects: [Project] {
        store.orderedProjects.filter {
            search.isEmpty || ([$0.title, $0.subtitle, $0.framework] + $0.tags).joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
                .navigationTitle(store.project?.title ?? "界面图鉴")
                .navigationSubtitle("本地界面学习画布")
        }
        .inspector(isPresented: $store.showingChat) {
            ChatPanel(chat: store.chat, root: store.root, runtime: store.runtime) { store.chat.send($0, root: store.root, runtime: store.runtime) }
                .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .toolbar { toolbar }
        .alert("无法打开项目", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("界面图鉴").font(.headline)
                    Text("收集界面，拆解设计").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            TextField("搜索作品、框架或标签", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                .accessibilityLabel("搜索作品")
            List {
                Section {
                    ForEach(projects) { project in
                        let pinned = store.pinned.contains(project.id)
                        Button { store.select(project) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                ProjectThumbnail(image: store.thumbnails[project.id], selected: project.id == store.project?.id)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 4) {
                                        Text(project.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        if pinned {
                                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("已置顶")
                                        }
                                        Spacer()
                                        if !project.enabled { Text("已停用").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    Text(project.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(detailLine(project)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!project.enabled)
                        .contextMenu {
                            Button(pinned ? "取消置顶" : "置顶") { store.togglePin(project.id) }
                        }
                        .listRowBackground(project.id == store.project?.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .accessibilityAddTraits(project.id == store.project?.id ? .isSelected : [])
                    }
                    if projects.isEmpty {
                        Text(search.isEmpty ? "目录中还没有作品" : "没有匹配的作品").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                } header: {
                    HStack {
                        Text("作品 · \(store.catalog?.projects.count ?? 0)")
                        Spacer()
                        Menu {
                            Picker("排序", selection: $store.projectOrder) {
                                Text("目录顺序").tag(ProjectOrder.catalog)
                                Text("最近修改").tag(ProjectOrder.recent)
                            }.pickerStyle(.inline)
                        } label: { Image(systemName: "arrow.up.arrow.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("排序：\(store.projectOrder == .recent ? "最近修改" : "目录顺序")").accessibilityLabel("作品排序")
                    }
                }
            }.listStyle(.sidebar).frame(minHeight: 120)
            if let project = store.project {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("关于作品").font(.caption).foregroundStyle(.secondary)
                        Text(project.description).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(project.author).font(.caption).foregroundStyle(.secondary)
                        if !project.tags.isEmpty { Text(project.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                        if let source = project.sourceUrl, let url = URL(string: source) {
                            Link(destination: url) { Label("查看原作出处", systemImage: "arrow.up.right") }.font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.frame(maxHeight: 220)
            }
            Divider()
            HStack {
                Circle().fill(store.ready ? .green : .secondary).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(statusLabel).font(.caption)
                Spacer()
                Button { store.chooseWorkspace() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("打开项目目录").accessibilityLabel("打开项目目录")
                    .disabled(store.opening)
            }.foregroundStyle(.secondary).padding(16)
        }
    }

    private func detailLine(_ project: Project) -> String {
        var parts = [project.framework, "\(project.frames.count) 个画框"]
        if let date = store.modified[project.id] { parts.append(Self.relative.localizedString(for: date, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    private var statusLabel: String {
        switch session.phase(for: store.project?.id) {
        case .ready: return "案例服务已就绪"
        case .starting: return "正在启动案例…"
        case .failed: return "案例服务启动失败"
        case .stopped: return "本地项目"
        }
    }

    @ViewBuilder private var detail: some View {
        if store.catalog == nil {
            ContentUnavailableView {
                Label("打开你的界面图鉴", systemImage: "square.stack.3d.up")
            } description: { Text("选择包含 catalog.json 的项目目录，开始浏览和比较界面。") }
            actions: { Button("打开项目目录…") { store.chooseWorkspace() }.buttonStyle(.borderedProminent) }
        } else if store.project == nil {
            ContentUnavailableView("没有已启用的作品", systemImage: "square.dashed", description: Text("在 catalog.json 中添加作品或启用已有作品，然后重新打开项目。"))
        } else {
            switch session.phase(for: store.project?.id) {
            case .starting, .stopped:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在启动「\(store.project?.title ?? "")」").font(.headline)
                    Text("首次打开作品时启动它的案例服务，可能需要一些时间。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("案例服务未能启动").font(.title2)
                    Text("确认已在项目目录执行 pnpm install，并检查下方端口或命令错误。修改过 catalog.json 时，请用“重新读取目录并启动服务”。").foregroundStyle(.secondary)
                    ScrollView { Text(message).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
                        .frame(maxWidth: 650, maxHeight: 220).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("选择项目目录…") { store.chooseWorkspace() }
                        Button("重新启动") { store.retryPreview() }.buttonStyle(.borderedProminent).disabled(store.opening)
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let project = store.project {
                    VStack(spacing: 0) {
                        NativeCanvas(project: project, positions: store.positions, positionsToken: store.positionsToken,
                                     viewportRequest: store.viewportRequest, tool: store.tool,
                                     reloadToken: store.reloadToken, zoomIndicator: store.zoomIndicator,
                                     onViewportSettled: store.viewportSettled,
                                     onFramesMoved: store.framesMoved,
                                     onSelectionChange: { store.selection = $0 },
                                     onToolChange: { store.tool = $0 },
                                     onFocusFrame: store.focusFrame,
                                     onCommand: { command in
                                         switch command {
                                         case .fitAll: store.fitAll()
                                         case .zoomToSelection: store.zoomToSelection()
                                         case .actualSize: store.zoom(1)
                                         }
                                     },
                                     onSizeChange: store.resize,
                                     onFrameReady: store.frameBecameReady,
                                     onCanvas: { store.canvas = $0 })
                            .clipped()
                        canvasFooter
                    }
                }
            }
        }
    }

    private var canvasFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                Spacer()
                Text("点选画框后可直接操作 · 空格拖动平移 · ⌘滚轮或捏合缩放 · Shift+1 适应全部").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("工具", selection: $store.tool) {
                Label("移动 V", systemImage: "cursorarrow").tag(CanvasTool.move)
                Label("抓手 H", systemImage: "hand.raised").tag(CanvasTool.hand)
            }
            .pickerStyle(.segmented).labelsHidden().disabled(store.project == nil)
            .help("移动（V）/ 抓手（H）").accessibilityLabel("画布工具")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("缩小（⌘−）").accessibilityLabel("缩小").disabled(store.project == nil)
            ZoomLabel(indicator: store.zoomIndicator) { store.zoom(1) }
                .disabled(store.project == nil)
            Button { store.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("放大（⌘+）").accessibilityLabel("放大").disabled(store.project == nil)
            Button { store.fitAll() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("适应全部（⌘0）").accessibilityLabel("适应全部").disabled(store.project == nil)
            Divider()
            Button { store.reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                .help("重新加载案例（⌘R）").accessibilityLabel("重新加载案例").disabled(!store.ready)
            Menu {
                Picker("外观", selection: $store.theme) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Divider()
                Button("恢复默认布局") { store.reset() }.disabled(store.project == nil)
                Button("重新读取目录并启动服务") { store.restart() }.disabled(store.root == nil || store.opening)
                Button("打开项目目录…") { store.chooseWorkspace() }.disabled(store.opening)
            } label: { Image(systemName: "slider.horizontal.3") }.help("外观与布局").accessibilityLabel("外观与布局")
            Toggle(isOn: $store.showingChat) { Image(systemName: "bubble.left.and.text.bubble.right") }
                .help("对话（⌘⇧A）").accessibilityLabel("对话").keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}

/// 作品缩略图；尚未生成时显示占位图。
private struct ProjectThumbnail: View {
    let image: NSImage?
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.quaternary.opacity(0.6))
            .overlay(alignment: .top) {
                // 长页面显示顶部，与画框首屏一致。
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            }
            .overlay { if image == nil { Image(systemName: "photo").foregroundStyle(.tertiary) } }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                                                   lineWidth: selected ? 1.5 : 0.5))
            .accessibilityHidden(true)
    }
}

private struct ZoomLabel: View {
    @ObservedObject var indicator: ZoomIndicator
    let action: () -> Void

    var body: some View {
        Button("\(Int((indicator.scale * 100).rounded()))%", action: action)
            .monospacedDigit().frame(minWidth: 44).help("实际大小（⌘1）")
    }
}
