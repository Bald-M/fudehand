# Sidebar Thumbnails, Recently Modified, and Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sidebar shows a cached thumbnail and last modified time for each web project, and supports switching sort order and pinning (#24).

**Architecture:** Sorting and directory scanning are pure AtlasCore logic; `AtlasStore` holds and persists pins, the sort preference, modification times, and thumbnails; the canvas calls back to the store to take a screenshot when a frame becomes ready.

**Tech Stack:** Swift 6 / SwiftUI / AppKit / WebKit, swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-17-sidebar-thumbnails-design.md`

## Global Constraints

- Do not change the `catalog.json` format; UI text is in Chinese.
- Pins are stored in UserDefaults `native.pinned.<root path>`; sort order is stored in `native.projectOrder` (values `catalog` / `recent`).
- Thumbnail cache `~/Library/Caches/界面图鉴/thumbnails/<first 16 chars of root path SHA256>/<web project id>.png`, 320px wide.
- App launch and service startup must not wait for directory scanning or thumbnails.

## Review Focus

- Web project directory missing or empty → `lastModified` returns nil, sorts last under Recently modified (最近修改), and does not crash.
- New files in `node_modules`, `.git`, or `dist` must not affect the modification time.
- Pinned list contains ids already removed from the catalog → ignored, does not affect sorting.
- Switching workspaces → pins, modification times, and thumbnails switch to the new workspace's.
- Screenshot failure (frame reload, process termination) → keep the old thumbnail, no error alert.

---

### Task 1: AtlasCore `SidebarOrdering`

**Files:** Create `native/Sources/AtlasCore/SidebarOrdering.swift`; Test `native/Tests/AtlasCoreTests/SidebarOrderingTests.swift`

**Produces:**
- `public enum ProjectOrder: String, CaseIterable { case catalog, recent }`
- `public enum SidebarOrdering { static func order(_ projects: [Project], by: ProjectOrder, pinned: Set<String>, modified: [String: Date]) -> [Project]; static func lastModified(directory: URL) -> Date? }`

- [ ] Tests: `catalogOrderKeepsCatalogWithPinnedFirst`, `recentOrderSortsDescendingUnknownLast`, `stalePinnedIdsIgnored`, `lastModifiedSkipsIgnoredDirectories` (in a temp directory, `src/a.txt` set to 2020 and `node_modules/x`, `.git/y`, `dist/z` set to 2025 → result is 2020), `lastModifiedMissingDirectoryIsNil`
- [ ] Run `swift test --package-path native --filter SidebarOrderingTests` and confirm it fails
- [ ] Implement; ignore list `node_modules`, `dist`, `build` and entries starting with `.`, using `FileManager.enumerator` + `skipDescendants`
- [ ] Commit after tests pass

### Task 2: `AtlasStore` pinning, sorting, modification times, thumbnails

**Files:** Modify `native/Sources/AtlasApp/AtlasStore.swift`; Create `native/Sources/AtlasApp/ThumbnailCache.swift`; Test `native/Tests/AtlasAppTests/StoreTests.swift`

**Produces:**
- `AtlasStore.pinned: Set<String>`, `togglePin(_ id: String)`, `projectOrder: ProjectOrder`, `modified: [String: Date]`, `thumbnails: [String: NSImage]`, `orderedProjects: [Project]`, `frameBecameReady(_ frameID: String)`
- `AtlasStore.init(defaults: UserDefaults = .standard, thumbnailRoot: URL? = nil)` (injected in tests)
- `ThumbnailCache(directory: URL)`: `load(_ id:) -> NSImage?`, `save(_ png: Data, id:) throws -> NSImage` (downscales to 320px wide before writing), `static func directory(for root: URL, base: URL) -> URL`

- [ ] Tests: `pinsPersistPerWorkspace` (UserDefaults in a separate suite; open a temporary catalog workspace → togglePin → a new store opening the same directory is still pinned), `projectOrderPersists`, `thumbnailCacheRoundTripsDownscaled` (2× 640-wide PNG → reads back 320px wide)
- [ ] Run and confirm failure; implement; on `open`, read pinned, load cached thumbnails, scan modification times with `Task.detached` and assign back on the main thread
- [ ] Commit after tests pass

### Task 3: Canvas callback and sidebar UI

**Files:** Modify `CanvasView.swift` (`onFrameReady: ((String) -> Void)?`, called on ready in `frameReadinessChanged`), `NativeCanvas.swift`, `WorkspaceView.swift`

- [ ] Sidebar row: 64×40 thumbnail/placeholder, pin, relative time; context menu Pin/Unpin (置顶/取消置顶); sort menu in the Section header
- [ ] `pnpm test:native` all pass; `pnpm dev` screenshots in light/dark saved to `docs/evidence/sidebar-thumbnails-{light,dark}.png`
- [ ] Commit
