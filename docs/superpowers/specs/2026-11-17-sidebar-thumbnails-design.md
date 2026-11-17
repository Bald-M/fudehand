# Sidebar: Web Project Thumbnails, Recently Modified, and Pinning (#24)

## Intent

Once there are many web projects, the sidebar only has titles and search, making it hard to recognize web projects at a glance or to see which one was edited recently.

## Goals

- Each web project shows a thumbnail: a rendered screenshot of that web project's **first frame** (in catalog order), cached locally; a placeholder is shown until it is generated.
- Show the last modified time (the latest modification time of files under the web project's `preview.cwd` directory), with sorting switchable between Catalog order (目录顺序) and Recently modified (最近修改).
- Frequently used web projects can be pinned; pinned web projects come first under both sort orders, and within the pinned set the current sort order applies.

## Non-goals

- Do not change the `catalog.json` format.
- No tag filtering, folder grouping, or analytics.

## Approach

Options considered:

1. **(Adopted) Screenshot and cache after a frame finishes loading**: reuse `PreviewFrameView.snapshotPNG()`; every time the first frame becomes ready, take a screenshot, downscale it to 320px wide, and write it to `~/Library/Caches/界面图鉴/thumbnails/<workspace path hash>/<web project id>.png`. Only web projects that have been opened get thumbnails; the rest show a placeholder. No extra web views are started, and launch is not blocked.
2. Open an offscreen WKWebView in the background for every web project to take screenshots: gets everything at once, but requires loading all web projects simultaneously, uses a lot of memory, and conflicts with "do not block launch".
3. Store in the catalog or the web project directory: violates the non-goals and pollutes the user's repository.

## Design

- **AtlasCore / `SidebarOrdering`** (pure logic, testable)
  - `ProjectOrder`: `.catalog` (catalog order) / `.recent` (recently modified, descending; unknown times go last, and entries that are both unknown keep catalog order).
  - `order(_ projects:, by:, pinned:, modified:) -> [Project]`: pinned first, stable sort.
  - `lastModified(directory:) -> Date?`: recursive scan, skipping entries starting with `.` as well as `node_modules`, `dist`, and `build`; only regular files are considered.
- **AtlasApp / `AtlasStore`**
  - `pinned: Set<String>`, UserDefaults key `native.pinned.<root>`; `togglePin(_:)`.
  - `projectOrder: ProjectOrder`, UserDefaults key `native.projectOrder` (global preference).
  - `modified: [String: Date]`: scanned in a background task after `open`, then published back on the main thread; does not block service startup.
  - `thumbnails: [String: NSImage]`: read from the cache directory on `open`; `frameBecameReady(projectID:frameID:)`, if it is the first frame, takes a screenshot, downscales it, writes the cache, and updates.
- **Canvas**: the `AtlasCanvasView.onFrameReady` callback fires when a frame becomes ready and is wired to the store through `NativeCanvas`.
- **Sidebar** (`WorkspaceView`): each row has a 64×40 thumbnail on the left (placeholder: rounded background + `photo` icon), a pin next to the title, and a third line showing "framework · N frames · relative time" (框架 · N 个画框 · 相对时间); a row context menu with Pin / Unpin (置顶 / 取消置顶); a sort menu in the list Section header (Catalog order / Recently modified).

## Decisions left to the implementer (my judgment)

- Thumbnail width 320px (displayed at 64pt in the row, covering 2× screens with headroom).
- The sort preference is global; pinning is per workspace.
- Relative time uses `RelativeDateTimeFormatter` (Chinese localization).
