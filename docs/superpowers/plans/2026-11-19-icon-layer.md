# Icon Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `icon` layer type that stores `library/name` + color, draws sharp at any zoom, and ships SF Symbols (system), Material Symbols (3 styles), WeUI, and Lucide, with an Agent search tool.

**Architecture:** A Node script extracts SVGs from three npm packages into compressed per-library resources in `FudehandCore`. `IconCatalog` (Core) loads them lazily, answers existence/search/suggestions, and takes injected SF Symbols functions from the App. `DesignJSON` validates only the name's syntax; `ControlCommands` additionally rejects unknown names for Agent edits. `IconLayer` (App) rasterizes and tints the shape into `contents`.

**Tech Stack:** Swift 6 (Swift 5 mode), SwiftPM, AppKit/Core Animation, Node 22 + Vitest, pnpm.

**Spec:** `docs/superpowers/specs/2026-11-19-icon-layer-design.md`

## Global Constraints

- Library ids exactly: `sf`, `material-outlined`, `material-rounded`, `material-sharp`, `weui`, `lucide`. Names are `<library>/<name>`; Material fill variants are `<name>.fill`.
- Pinned dev dependencies: `lucide-static@1.75.0`, `@material-symbols/svg-400@0.49.0`, `weui@2.6.26`.
- `DesignDocument.formatVersion` becomes 4; versions 1–3 open unchanged.
- Icon default size 24 × 24; `icon.color` default `#000000`; drawn centered, aspect-fit.
- Icons support `opacity, visible, locked, fill, stroke, sizing, interaction, animation`; reject `cornerRadius, children, layout, clipsContent, text, image`.
- Unknown-name error text: `Unknown icon <name>; similar: a, b, c` (up to 5 suggestions; `; similar: …` omitted when none).
- `FudehandCore` must not import AppKit.
- All new UI copy via `L("…")` in all four `Localizable.strings`; docs, comments, errors in English.
- Do not run two Swift builds on the same scratch directory at once.

## Review Focus

1. A `.fudehand` file with an unknown icon (e.g. `sf/some.future.symbol`) opens, renders a placeholder, and other fields of that layer can still be updated by the Agent — Task 5 test `updatingOtherFieldsOfUnknownIconIsAllowed`.
2. Non-square icon layer (e.g. 48 × 24) draws the icon aspect-fit and centered, not stretched — Task 4 test `iconRasterIsAspectFitAndCentered`.
3. Recoloring an icon re-rasterizes without a size change — Task 4 test `colorChangeReRasterizes`.
4. Case/whitespace in search queries (`"  House "`) still finds `lucide/house` — Task 3 test `searchIsCaseInsensitiveAndTrimmed`.
5. Creating a subtree where a nested child has an unknown icon fails as a whole and creates nothing — Task 5 test `unknownNestedIconCreatesNothing`.

---

### Task 1: Icon data build

**Files:**
- Modify: `package.json` (devDependencies + script `"build:icons": "node scripts/build-icons.mjs"`)
- Create: `scripts/build-icons.mjs`
- Create (generated, committed): `native/Sources/FudehandCore/Resources/Icons/{material-outlined,material-rounded,material-sharp,weui,lucide}.json.zlib`, `native/Sources/FudehandCore/Resources/Icons/LICENSES.txt`
- Test: `tests/build-icons.test.ts`

**Interfaces:**
- Produces: each `.json.zlib` is raw DEFLATE (`zlib.deflateRawSync`) of JSON `{ "library": "<id>", "version": "<pkg version>", "icons": { "<name>": { "svg": "<minimal svg>", "tags": ["…"] } } }` (`tags` only for Lucide, from `tags.json`). Exports from `scripts/build-icons.mjs`: `minifySVG(source: string): string`, `materialName(file: string): string` (`home-fill.svg` → `home.fill`, `home.svg` → `home`), `weuiIcons(less: string): Record<string, string>` (class `.weui-icon-success` with `mask-image: url(data:image/svg+xml,…)` → `{ success: '<svg …>' }`, URI-decoded). The script runs `main()` only when executed directly.

- [ ] **Step 1: Install dev dependencies** — `pnpm add -D lucide-static@1.75.0 @material-symbols/svg-400@0.49.0 weui@2.6.26`
- [ ] **Step 2: Write failing tests** in `tests/build-icons.test.ts`:
  - `minifySVG` removes comments, `class`, `width`, `height`, collapses whitespace, keeps `viewBox`, `fill`, `stroke*` attributes and child elements; result starts with `<svg` and contains `viewBox="0 0 24 24"` for Lucide's `house.svg`.
  - `materialName('home-fill.svg') === 'home.fill'`, `materialName('10k.svg') === '10k'`.
  - `weuiIcons` on the real `node_modules/weui/src/style/icon/weui-icon.less` returns 27 entries, including `success`, `search`, `close`, each a string starting with `<svg`.
- [ ] **Step 3: Run** `pnpm vitest run tests/build-icons.test.ts` — expect FAIL (module missing).
- [ ] **Step 4: Implement** `scripts/build-icons.mjs`; output dir `native/Sources/FudehandCore/Resources/Icons`. `LICENSES.txt` concatenates, under a header per library with name + version, the full text of `lucide-static/LICENSE`, `@material-symbols/svg-400/LICENSE`, `weui/LICENSE.txt`.
- [ ] **Step 5: Run** the tests — PASS. Then `pnpm build:icons`; confirm five `.json.zlib` files exist and total under 6 MB (`du -ch native/Sources/FudehandCore/Resources/Icons`).
- [ ] **Step 6: Commit** — `feat(icons): 构建脚本打包 Material、WeUI、Lucide 图标数据`

### Task 2: Document model and validation

**Files:**
- Modify: `native/Sources/FudehandCore/DesignDocument.swift`, `native/Sources/FudehandCore/DesignJSON.swift`
- Test: `native/Tests/FudehandCoreTests/IconLayerTests.swift`

**Interfaces:**
- Produces: `NodeType.icon` (title `L("Icon")`, `hasChildren == false`, `hasCornerRadius == false`); `public struct DesignIcon: Equatable, Sendable { public var name: String; public var color: DesignColor }`; `DesignNode.icon: DesignIcon?`; `public enum IconLibrary: String, CaseIterable, Sendable { case sf, materialOutlined = "material-outlined", materialRounded = "material-rounded", materialSharp = "material-sharp", weui, lucide }`; `IconLibrary.parse(_ fullName: String) -> (library: IconLibrary, name: String)?`; `DesignDocument.formatVersion == 4`; `"icon"` in `DesignJSON.nodeKeys` and `nestedKeys`.

- [ ] **Step 1: Write failing tests:** `iconRoundTripsThroughFile` (encode/decode keeps name, color, size); `iconColorDefaultsToBlack` (`{"id":"i","type":"icon","icon":{"name":"lucide/house"}}` → color `#000000`; the 24 × 24 default size is applied by the control channel, Task 5, since files always carry width and height); `iconRequiresIcon` error `Layer i: icon layer is missing icon`; `iconRejectsBadName` for `"house"`, `"foo/house"`, `"lucide/"` → error contains `icon.name must be <library>/<name> with library one of sf, material-outlined, material-rounded, material-sharp, weui, lucide`; `iconRejectsUnsupportedFields` for `cornerRadius`, `children`, `layout`, `text`, `image`; `iconAcceptsAnimation`; `unknownIconNameStillDecodes` (`sf/not.a.real.symbol` decodes); `iconPatchMergesColor` via `DesignJSON.apply(["icon": ["color": "#FF0000"]])` keeps the name; `version4IsWrittenAndVersion3Opens`.
- [ ] **Step 2: Run** `swift test --package-path native --filter FudehandCoreTests.IconLayerTests` — FAIL.
- [ ] **Step 3: Implement** the types and `DesignJSON` reading/writing; fix every exhaustive `switch` over `NodeType` the compiler reports (App included: treat `.icon` like `.rectangle` unless the spec says otherwise). Add `"Icon"` to all four string tables.
- [ ] **Step 4: Run** the filter, then `pnpm test:native` — PASS.
- [ ] **Step 5: Commit** — `feat(canvas): 新增 icon 图层类型与字段校验`

### Task 3: Icon catalog

**Files:**
- Create: `native/Sources/FudehandCore/IconCatalog.swift`
- Test: `native/Tests/FudehandCoreTests/IconCatalogTests.swift`

**Interfaces:**
- Consumes: `IconLibrary` (Task 2), the resources from Task 1.
- Produces:
  ```swift
  public final class IconCatalog: @unchecked Sendable {
      public static let shared: IconCatalog
      public init(bundle: Bundle = .module, symbolExists: @escaping @Sendable (String) -> Bool = { _ in false },
                  symbolNames: @escaping @Sendable () -> [String] = { [] })
      public var symbolExists: @Sendable (String) -> Bool   // set by the App at launch
      public var symbolNames: @Sendable () -> [String]
      public func svg(_ fullName: String) -> Data?            // bundled libraries only
      public func exists(_ fullName: String) -> Bool
      public func suggestions(for fullName: String, limit: Int = 5) -> [String]
      public func search(_ query: String, library: IconLibrary? = nil, limit: Int = 50) -> [String]
  }
  ```
  Thread-safe lazy loading with an `NSLock`; `sf` names cached after first `symbolNames()` call.

- [ ] **Step 1: Write failing tests:** `bundledIconsExist` (`lucide/house`, `material-outlined/home`, `material-rounded/home.fill`, `material-sharp/search`, `weui/success` exist; `lucide/nope` does not); `svgIsParseable` (`DesignJSON.isSVG(svg("lucide/house")!)`); `sfUsesInjectedFunctions` (catalog with `symbolExists: { $0 == "house" }`, `symbolNames: { ["house", "house.fill"] }` → `exists("sf/house")`, `search("house", library: .sf) == ["sf/house", "sf/house.fill"]`); `searchRanksExactThenPrefixThenSubstringThenTag` (Lucide: `search("house", library: .lucide).first == "lucide/house"`; a tag-only hit ranks after name hits); `searchIsCaseInsensitiveAndTrimmed`; `searchRespectsLimit`; `suggestionsPreferSameLibrary` (`suggestions(for: "lucide/hous")` contains `lucide/house` and only `lucide/` names first); `suggestionsForUnknownLibraryAreEmpty`.
- [ ] **Step 2: Run** `swift test --package-path native --filter FudehandCoreTests.IconCatalogTests` — FAIL.
- [ ] **Step 3: Implement.** Decompress with `(data as NSData).decompressed(using: .zlib)`. Ranking score per name (lower is better): 0 exact, 1 prefix, 2 contains, 3 any tag contains the query; ties by name length then alphabetical. Without `library`, search all libraries (SF included). Suggestions: candidates in the same library scored by Levenshtein distance on the name part, with names containing the query (or contained in it) first.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(icons): 图标目录支持查询、搜索与相近名字`

### Task 4: Rendering

**Files:**
- Modify: `native/Sources/FudehandApp/DesignRenderer.swift`, `native/Sources/FudehandApp/FudehandApp.swift` (or the store's init — wherever app-launch setup lives)
- Create: `native/Sources/FudehandApp/IconLayer.swift`, `native/Sources/FudehandApp/SystemSymbols.swift`
- Test: `native/Tests/FudehandAppTests/IconRendererTests.swift`

**Interfaces:**
- Consumes: `DesignIcon`, `IconCatalog.shared`.
- Produces: `final class IconLayer: CALayer` with `@MainActor func update(_ icon: DesignIcon)`, `@MainActor func rasterize(force: Bool)`, `@MainActor func invertForSnapshot()`, `var isPlaceholder: Bool`; `enum SystemSymbols { static func exists(_ name: String) -> Bool; static func names() -> [String]; static func install() }` where `install()` sets `IconCatalog.shared.symbolExists/symbolNames` and is called at App launch. `names()` reads the `symbols` dictionary keys of `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist`, returning `[]` on any failure.

- [ ] **Step 1: Write failing tests** (follow `DesignRendererTests.swift` setup): `iconRasterIsAspectFitAndCentered` (48 × 24 `lucide/house` black: pixel columns outside the centered 24 × 24 square are transparent); `iconIsTintedWithColor` (`#FF0000` → an opaque pixel is red); `colorChangeReRasterizes`; `zoomInRerasterizesSharp` (scale 8 → `contents` pixel width ≥ 24 × 8 × screen scale capped by `rasterScale`); `unknownIconIsPlaceholder` (`isPlaceholder == true`, contents non-nil); `sfSymbolRenders` (`sf/house.fill` → not placeholder, has opaque pixels); `snapshotShowsIcon` (`DesignRenderer.snapshotPNG` of a frame containing a red icon has red pixels at the icon's location, upright — top half of an arrow-up icon check or compare against the non-flipped raster).
- [ ] **Step 2: Run** `swift test --package-path native --filter FudehandAppTests.IconRendererTests` — FAIL.
- [ ] **Step 3: Implement.** Shape source: bundled → `NSImage(data: svg)`; `sf` → `NSImage(systemSymbolName:accessibilityDescription:)` with `.withSymbolConfiguration(.init(pointSize: side, weight: .regular))`. Draw aspect-fit into a bitmap of bounds × `contentsScale` (via `DesignRenderer.rasterScale`), then fill the color with `.sourceIn`. Reuse the image layer's tiered re-rasterization rule (1.5× headroom, force on zoom settle). Placeholder: 10% black fill, 1 px 30% black border, one diagonal line. In `makeLayer`, `.icon` → `IconLayer`; in `apply`, set `contentsScale` for icons as for images; snapshot flips icon bitmaps like image bitmaps.
- [ ] **Step 4: Run** — PASS; then `pnpm test:native`.
- [ ] **Step 5: Commit** — `feat(canvas): 画布按矢量绘制图标图层并支持快照`

### Task 5: Control channel

**Files:**
- Modify: `native/Sources/FudehandCore/ControlProtocol.swift`, `native/Sources/FudehandApp/ControlCommands.swift`
- Test: `native/Tests/FudehandCoreTests/ControlProtocolTests.swift`, `native/Tests/FudehandAppTests/StoreTests.swift`

**Interfaces:**
- Consumes: `IconCatalog.shared`.
- Produces: `ControlCommand.searchIcons(query: String, library: String?, limit: Int)` parsed from `search_icons` (`query` required string; `library` optional, must be a known id else `library must be one of …`; `limit` optional integer 1–200, default 50). Result `{ "icons": ["lucide/house", …] }`. `create_node` with `type: "icon"` and no `width`/`height` gets 24 × 24.

- [ ] **Step 1: Write failing tests:** protocol parse of `search_icons` (valid, bad library, bad limit); store: `createIconLayer` (24 × 24, readable back); `unknownIconIsRejectedWithSuggestions` (`lucide/hous` → error `Unknown icon lucide/hous; similar: lucide/house…`, document unchanged); `unknownNestedIconCreatesNothing`; `updateToUnknownIconIsRejected`; `updatingOtherFieldsOfUnknownIconIsAllowed` (open a document containing `sf/not.real`, update `x` succeeds); `searchIconsReturnsNames`; `iconSnapshotViaControl`.
- [ ] **Step 2: Run** the two filters — FAIL.
- [ ] **Step 3: Implement.** In `createNode`, after `DesignJSON.node`, walk the subtree and throw on the first icon whose name `!IconCatalog.shared.exists`. In `updateNode`, check only when `changes["icon"]?["name"]` is present. Default 24 × 24 is applied to the JSON object before `DesignJSON.node` when `type == "icon"` and the key is absent.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `feat(agent): 控制通道支持搜索图标并校验图标名字`

### Task 6: Agent tools and design guidance

**Files:**
- Modify: `scripts/fudehand-tools.mjs`, `scripts/design-guidance.mjs`
- Test: `tests/control-tools.test.ts`, `tests/mcp-server.test.ts` (tool list), `tests/agent-chat.test.ts` if it lists tools

**Interfaces:**
- Produces: tool `design_search_icons` → command `search_icons`, properties `query` (string, required), `library` (enum of the six ids), `limit` (integer 1–200); placed right after `design_import_font` in `tools`. `NODE_GUIDE` lists `icon` in the type list and adds `icon {name "<library>/<name>" from design_search_icons, color} (required for icon; size is width/height, default 24×24; drawn as a single-color vector)`; `cornerRadius` list unchanged.

- [ ] **Step 1: Update the tool-list expectation and add tests:** `design_search_icons` forwards `{ query, library, limit }` unchanged; `design_create_node` description contains `icon`, `design_search_icons`, `material-rounded`; design guidance contains `sf`, `material-`, `weui`, `lucide`.
- [ ] **Step 2: Run** `pnpm vitest run tests/control-tools.test.ts` — FAIL.
- [ ] **Step 3: Implement.** Guidance paragraph (under "Quality floor" or a new "Icons" heading): use real icons instead of shapes or words; choose the library by target platform — Apple `sf`, Android one `material-*` style, WeChat mini program `weui`, web `lucide`; call `design_search_icons` before using a name; keep one library and style per screen.
- [ ] **Step 4: Run** `pnpm check` — PASS.
- [ ] **Step 5: Commit** — `feat(agent): 新增 design_search_icons 工具与图标设计指引`

### Task 7: Layers panel and inspector

**Files:**
- Modify: `native/Sources/FudehandApp/LayersPanel.swift`, `native/Sources/FudehandApp/InspectorPanel.swift`, four `Localizable.strings`
- Test: `native/Tests/FudehandCoreTests/LocalizationTests.swift` (existing checks), `native/Tests/FudehandAppTests/StoreTests.swift`

**Interfaces:**
- Consumes: `DesignIcon`.
- Produces: layers glyph `"star.square"` for `.icon`; inspector section `L("Icon")` showing the name as read-only text and `ColorRow(label: L("Icon color"), …)` calling `update("Change Icon Color", "icon.color") { $0.icon?.color = c }`.

- [ ] **Step 1: Write failing test** `iconColorChangeIsOneUndoStep` in `StoreTests` (change color through the same store update path the inspector uses, undo restores the old color).
- [ ] **Step 2: Run** — FAIL; implement; add `"Icon color"` and `"Change Icon Color"` (if undo names are localized — follow how `"Change Text Color"` is handled) to all four tables, with zh-Hans `图标颜色`, zh-Hant `圖示顏色`.
- [ ] **Step 3: Run** `pnpm test:native` — PASS.
- [ ] **Step 4: Commit** — `feat(inspector): 属性面板可修改图标颜色`

### Task 8: Docs and evidence

**Files:**
- Create: `docs/adr/0008-icon-layer.md`, `docs/evidence/icon-layer-light.jpg`, `docs/evidence/icon-layer-dark.jpg`
- Modify: `GLOSSARY.md` (Icon layer, Icon library, Icon name), `docs/agent-tools.md` (coverage row for icon layers and `design_search_icons`), `docs/macos.md` (icon layer behavior, placeholder), `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Write the ADR**: context, decision (approach 1 from the spec), rejected alternatives (fonts, SVG in document), consequences including the SF Symbols terms (use only in mockups of apps for Apple platforms; not bundled; not enforced) and the undocumented `name_availability.plist`, and the bundled licenses in `Resources/Icons/LICENSES.txt`.
- [ ] **Step 2: Update the other docs.**
- [ ] **Step 3: Evidence:** `pnpm dev`; through MCP create a frame with one icon from each of the six libraries in two colors, zoom to 800%; screenshot in light and dark appearance; save the two JPGs.
- [ ] **Step 4: Full gate:** `pnpm test:native` and `pnpm check` — both PASS.
- [ ] **Step 5: Commit** — `docs(icons): 图标图层 ADR、术语与界面证据`
