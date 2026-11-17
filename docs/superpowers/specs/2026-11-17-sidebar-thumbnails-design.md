# 侧栏：作品缩略图、最近修改与置顶（#24）

## 意图

作品多了以后，侧栏只有标题和搜索，难以一眼认出作品，也看不出最近在改哪个。

## 目标

- 每个作品显示缩略图：取自该作品**第一个画框**（catalog 顺序）的渲染截图，缓存在本地；未生成时显示占位图。
- 显示最近修改时间（作品 `preview.cwd` 目录下文件的最新修改时间），可在“目录顺序”和“最近修改”之间切换排序。
- 可以置顶常用作品；置顶作品在两种排序下都排在最前，置顶内部沿用当前排序。

## 非目标

- 不改 `catalog.json` 格式。
- 不做标签筛选、分组文件夹、统计分析。

## 方案

考虑过的做法：

1. **（采用）画框加载完成后截图并缓存**：复用 `PreviewFrameView.snapshotPNG()`；第一个画框每次变为就绪时截图、缩小到 320px 宽、写入 `~/Library/Caches/界面图鉴/thumbnails/<工作区路径哈希>/<作品 id>.png`。只有打开过的作品才有缩略图，其余显示占位图。不额外启动 web view，不阻塞启动。
2. 后台为所有作品各开一个离屏 WKWebView 截图：一次就能拿全，但要同时加载所有作品，耗内存、与“不阻塞启动”冲突。
3. 存放在 catalog 或作品目录中：违反非目标，且会污染用户仓库。

## 设计

- **AtlasCore / `SidebarOrdering`**（纯逻辑，可测）
  - `ProjectOrder`：`.catalog`（目录顺序）/ `.recent`（最近修改，降序；未知时间排后，同为未知保持目录顺序）。
  - `order(_ projects:, by:, pinned:, modified:) -> [Project]`：置顶在前，稳定排序。
  - `lastModified(directory:) -> Date?`：递归扫描，跳过以 `.` 开头的条目以及 `node_modules`、`dist`、`build`；只看普通文件。
- **AtlasApp / `AtlasStore`**
  - `pinned: Set<String>`，UserDefaults 键 `native.pinned.<root>`；`togglePin(_:)`。
  - `projectOrder: ProjectOrder`，UserDefaults 键 `native.projectOrder`（全局偏好）。
  - `modified: [String: Date]`：`open` 后在后台任务中扫描，完成后回主线程发布；不阻塞服务启动。
  - `thumbnails: [String: NSImage]`：`open` 时从缓存目录读取；`frameBecameReady(projectID:frameID:)` 若为第一个画框则截图、缩小、写缓存并更新。
- **画布**：`AtlasCanvasView.onFrameReady` 回调在画框变为就绪时触发，经 `NativeCanvas` 接到 store。
- **侧栏**（`WorkspaceView`）：每行左侧 64×40 缩略图（占位：圆角底 + `photo` 图标），标题旁置顶图钉，第三行显示“框架 · N 个画框 · 相对时间”；行右键菜单“置顶 / 取消置顶”；列表 Section 标题处一个排序菜单（目录顺序 / 最近修改）。

## 留给实现者的决定（我的判断）

- 缩略图宽 320px（行内显示 64pt，覆盖 2× 屏并留余量）。
- 排序偏好为全局；置顶按工作区区分。
- 相对时间用 `RelativeDateTimeFormatter`（中文本地化）。
