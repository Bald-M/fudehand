# 侧栏缩略图、最近修改与置顶 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 侧栏为每个作品显示缓存缩略图、最近修改时间，支持排序切换与置顶（#24）。

**Architecture:** 排序与目录扫描是 AtlasCore 纯逻辑；`AtlasStore` 持有置顶、排序偏好、修改时间和缩略图并持久化；画布在画框就绪时回调 store 截图。

**Tech Stack:** Swift 6 / SwiftUI / AppKit / WebKit，swift-testing。

**Spec:** `docs/superpowers/specs/2026-11-17-sidebar-thumbnails-design.md`

## Global Constraints

- 不改 `catalog.json` 格式；界面文案为中文。
- 置顶存 UserDefaults `native.pinned.<root path>`；排序存 `native.projectOrder`（值 `catalog` / `recent`）。
- 缩略图缓存 `~/Library/Caches/界面图鉴/thumbnails/<root 路径 SHA256 前 16 位>/<作品 id>.png`，宽 320px。
- 启动与服务启动不得等待目录扫描或缩略图。

## Review Focus

- 作品目录不存在或为空 → `lastModified` 返回 nil，排在“最近修改”末尾，不崩溃。
- `node_modules`、`.git`、`dist` 中的新文件不得影响修改时间。
- 置顶列表含已从 catalog 删除的 id → 忽略，不影响排序。
- 切换工作区 → 置顶、修改时间、缩略图换成新工作区的。
- 截图失败（画框重载、进程终止）→ 保留旧缩略图，不弹错误。

---

### Task 1: AtlasCore `SidebarOrdering`

**Files:** Create `native/Sources/AtlasCore/SidebarOrdering.swift`；Test `native/Tests/AtlasCoreTests/SidebarOrderingTests.swift`

**Produces:**
- `public enum ProjectOrder: String, CaseIterable { case catalog, recent }`
- `public enum SidebarOrdering { static func order(_ projects: [Project], by: ProjectOrder, pinned: Set<String>, modified: [String: Date]) -> [Project]; static func lastModified(directory: URL) -> Date? }`

- [ ] 测试：`catalogOrderKeepsCatalogWithPinnedFirst`、`recentOrderSortsDescendingUnknownLast`、`stalePinnedIdsIgnored`、`lastModifiedSkipsIgnoredDirectories`（临时目录中 `src/a.txt` 设为 2020 年、`node_modules/x`、`.git/y`、`dist/z` 设为 2025 年 → 结果为 2020 年）、`lastModifiedMissingDirectoryIsNil`
- [ ] 运行 `swift test --package-path native --filter SidebarOrderingTests`，确认失败
- [ ] 实现；忽略名单 `node_modules`、`dist`、`build` 及 `.` 开头条目，用 `FileManager.enumerator` + `skipDescendants`
- [ ] 测试通过后提交

### Task 2: `AtlasStore` 置顶、排序、修改时间、缩略图

**Files:** Modify `native/Sources/AtlasApp/AtlasStore.swift`；Create `native/Sources/AtlasApp/ThumbnailCache.swift`；Test `native/Tests/AtlasAppTests/StoreTests.swift`

**Produces:**
- `AtlasStore.pinned: Set<String>`、`togglePin(_ id: String)`、`projectOrder: ProjectOrder`、`modified: [String: Date]`、`thumbnails: [String: NSImage]`、`orderedProjects: [Project]`、`frameBecameReady(_ frameID: String)`
- `AtlasStore.init(defaults: UserDefaults = .standard, thumbnailRoot: URL? = nil)`（测试注入）
- `ThumbnailCache(directory: URL)`：`load(_ id:) -> NSImage?`、`save(_ png: Data, id:) throws -> NSImage`（缩小到 320px 宽后写入）、`static func directory(for root: URL, base: URL) -> URL`

- [ ] 测试：`pinsPersistPerWorkspace`（独立 suite 的 UserDefaults；open 临时 catalog 工作区 → togglePin → 新 store 再 open 同目录仍置顶）、`projectOrderPersists`、`thumbnailCacheRoundTripsDownscaled`（2× 640 宽 PNG → 读回宽 320px）
- [ ] 运行确认失败；实现；`open` 时读 pinned、加载缓存缩略图、`Task.detached` 扫描修改时间后回主线程赋值
- [ ] 测试通过后提交

### Task 3: 画布回调与侧栏界面

**Files:** Modify `CanvasView.swift`（`onFrameReady: ((String) -> Void)?`，在 `frameReadinessChanged` 中就绪时调用）、`NativeCanvas.swift`、`WorkspaceView.swift`

- [ ] 侧栏行：64×40 缩略图/占位、置顶图钉、相对时间；右键“置顶/取消置顶”；Section 头部排序菜单
- [ ] `pnpm test:native` 全部通过；`pnpm dev` 在浅色/深色下截图存 `docs/evidence/sidebar-thumbnails-{light,dark}.png`
- [ ] 提交
