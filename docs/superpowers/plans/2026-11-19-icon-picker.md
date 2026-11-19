# Icon Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A person can search the built-in icon libraries, insert an icon layer from the bottom canvas toolbar, and replace the icon of a selected icon layer from the inspector.

**Architecture:** `IconCatalog` (FudehandCore) gains a listing for one library (all names when the query is empty, search results otherwise). A new SwiftUI `IconPicker` view shows a library switcher, a search field, and a lazy grid of cached template thumbnails; the toolbar and the inspector open it in a popover. Two store methods, `insertIcon(_:)` and `replaceIcon(_:with:)`, make the edits as one undo step each.

**Tech Stack:** Swift 6 (Swift 5 language mode), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-19-icon-picker-design.md`

## Global Constraints

- No hard-coded UI copy: `L("English")`, with the key in all four `Localizable.strings` tables (en, en-GB, zh-Hans, zh-Hant), terms per `GLOSSARY.md`.
- New UI source files go into the `files` list of `uiSourcesHaveNoHardCodedChineseCopy` in `LocalizationTests.swift`.
- Inserted icon: 24 × 24, color `#000000`, layer name = the part of the icon name after `<library>/`; one undo step named `Insert Icon`.
- Replace: changes only `icon.name`; one undo step named `Replace Icon`.
- No new Agent tool; `docs/agent-tools.md` coverage table records the picker as covered by `design_search_icons` + `design_create_node` / `design_update_node`.
- Code comments, docs, and test names in English.

## Review Focus

- Empty or whitespace-only query → the whole library, not an empty grid.
- Inserting while a non-frame layer (or several layers) is selected → placed at the viewport center at top level, as Insert Image does.
- Replace on an icon layer whose current name is unknown to this Mac → still replaces; position, size, color unchanged.
- SF Symbols with no system catalog (search plist missing) → the SF library shows the empty state, not a crash.
- Switching library while a query is typed → the query applies to the new library.

---

### Task 1: Library listing in IconCatalog

**Files:**
- Modify: `native/Sources/FudehandCore/IconCatalog.swift`
- Test: `native/Tests/FudehandCoreTests/IconCatalogTests.swift`

**Interfaces:**
- Produces: `public func listing(_ query: String, library: IconLibrary) -> [String]` — full names (`<library>/<name>`). A query that is empty after `normalized` returns every name in the library sorted by `localizedStandardCompare`; otherwise `search(query, library: library, limit: .max)`.

- [ ] **Step 1: Write the failing tests** `listingWithoutAQueryIsTheWholeLibrarySorted` (weui: count equals the library's icon count, all start with `weui/`, sorted; `"  "` gives the same result), `listingWithAQuerySearchesOnlyThatLibrary` (`listing("house", library: .lucide)` first is `lucide/house`, all start with `lucide/`), `sfListingUsesTheInjectedNames` (catalog with `symbolNames = { ["b", "a"] }` → `["sf/a", "sf/b"]`; with no names → `[]`).
- [ ] **Step 2: Run** `swift test --package-path native --filter FudehandCoreTests.IconCatalog` — FAIL (no `listing`).
- [ ] **Step 3: Implement `listing`.**
- [ ] **Step 4: Run the same filter** — PASS.
- [ ] **Step 5: Commit** `feat(icons): 图标目录可按库列出全部图标`.

### Task 2: Store insert and replace

**Files:**
- Modify: `native/Sources/FudehandApp/FudehandStore.swift` (next to `insertImage`)
- Test: `native/Tests/FudehandAppTests/StoreTests.swift`

**Interfaces:**
- Produces: `func insertIcon(_ name: String)` and `func replaceIcon(_ id: String, with name: String)` on `FudehandStore`. Both report failures through `alert`, as `insertImage` does.
- Placement shared with `insertImage` via a private helper `insertionPlacement(width: Double, height: Double) -> (parent: String?, x: Double, y: Double)` (selected single frame → that frame at 0, 0; otherwise centered in the viewport at top level). `insertImage` uses it too, unchanged in behavior.

- [ ] **Step 1: Write failing tests** `insertingAnIconAddsOneSelectedLayerAtTheViewportCenter` (24 × 24, `icon == DesignIcon(name: "lucide/house")`, name `house`, selected, `editor.undoName == "Insert Icon"`, one undo removes it), `insertingAnIconWithAFrameSelectedPutsItInTheFrame` (parent is the frame, x = y = 0), `replacingAnIconKeepsFrameAndColor` (layer at 10, 20, 40 × 40, color `#336699`, name `sf/not.a.real.symbol` → after replace with `material-outlined/home`: same frame and color, new name, `undoName == "Replace Icon"`).
- [ ] **Step 2: Run** `swift test --package-path native --filter FudehandAppTests` — FAIL.
- [ ] **Step 3: Implement** the two methods and the shared placement helper; `replaceIcon` goes through `updateNode(id, "Replace Icon")`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(canvas): 商店支持插入与替换图标图层`.

### Task 3: Icon picker view, toolbar button, inspector Replace

**Files:**
- Create: `native/Sources/FudehandApp/IconPicker.swift`
- Modify: `native/Sources/FudehandApp/CanvasToolbar.swift`, `native/Sources/FudehandApp/InspectorPanel.swift`
- Modify: the four `Localizable.strings`, `native/Tests/FudehandCoreTests/LocalizationTests.swift` (add `IconPicker`)

**Interfaces:**
- Consumes: `IconCatalog.listing`, `store.insertIcon`, `store.replaceIcon`.
- Produces: `struct IconPicker: View { init(current: String?, choose: @escaping (String) -> Void) }`.

Behavior: a segmented control for SF Symbols / Material Symbols / WeUI / Lucide; for Material a style menu Outlined / Rounded / Sharp; a search field focused on appear; `ScrollView` + `LazyVGrid` of 40 pt cells with `.help(name)`; results computed off the main actor (a `.task(id:)` keyed on query + library); empty results → "No Icons" with the query; SF Symbols shows "SF Symbols may be used only in designs for Apple platforms." Opening with `current` selects that icon's library and style. Thumbnails: an `NSCache` of template `NSImage`s (`NSImage(data:)` of `IconCatalog.shared.svg`, or `NSImage(systemSymbolName:)` for `sf/`), shown with `.renderingMode(.template)` and `.foregroundStyle(.primary)`. Choosing calls `choose` and dismisses. Esc closes the popover (SwiftUI default).

Toolbar: an `Icon` `ToolButton` (symbol `star.square.on.square`) after Insert Image, presenting `IconPicker(current: nil) { store.insertIcon($0) }` in a `.popover`. Inspector: a `Replace Icon…` button in the Icon section presenting `IconPicker(current: icon.name) { store.replaceIcon(node.id, with: $0) }`.

- [ ] **Step 1: Run** `pnpm test:native` after adding copy — localization tests PASS (keys in all four tables, `IconPicker` listed).
- [ ] **Step 2: Build and check in the real app** (`pnpm dev`): open from the toolbar, type, switch libraries, empty state, insert, undo, replace from the inspector, light and dark.
- [ ] **Step 3: Commit** `feat(canvas): 底部工具条与属性面板新增图标选择面板`.

### Task 4: Docs and evidence

**Files:**
- Modify: `docs/macos.md` (toolbar line 60–62 and the inspector line), `docs/agent-tools.md` (coverage row for icon search), `GLOSSARY.md` (icon picker), `CHANGELOG.md`
- Create: `docs/evidence/icon-picker-light.jpg`, `docs/evidence/icon-picker-dark.jpg`

- [ ] **Step 1: Update the docs** per the spec's behavior.
- [ ] **Step 2: Run** `pnpm test:native` and `pnpm check` — both PASS.
- [ ] **Step 3: Commit** `docs(icons): 图标选择面板的交互说明与界面证据`.
