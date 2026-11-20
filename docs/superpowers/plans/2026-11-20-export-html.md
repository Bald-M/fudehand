# Export as HTML Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export one layer (usually a frame) as an HTML page with its images and icons, from the App (File > Export as HTML…, layer context menu) and from the Agent tool `design_export_html`, so an Agent can implement front-end code from a prototype.

**Architecture:** `FudehandCore/DesignHTML.swift` turns a laid-out `DesignNode` into `index.html` (one `<style>` block, one class per layer) plus asset files; it takes icon artwork through a closure so the App can rasterize SF Symbols. `FudehandStore.exportHTML(_:to:)` writes the files and is called by both the menu and the `export_html` control command.

**Tech Stack:** Swift 6 (Swift 5 mode), SwiftUI/AppKit, Node MCP tools, Vitest.

**Spec:** [Bald-M/fudehand#202](https://github.com/Bald-M/fudehand/issues/202), option A chosen in conversation: one feature "Export as HTML…" instead of separate asset export and copy-as-CSS.

## Global Constraints

- No third-party Swift packages; testable rules live in `FudehandCore`.
- One path (docs/agent-tools.md §2): the tool forwards `export_html` to the App, which calls the same store method as the menu. Node only resolves a relative `directory` against the repository root, like other path arguments.
- No modal UI for the tool; errors in English, unlocalized.
- UI copy via `L("…")` with entries in all four `Localizable.strings`.
- Output is a reference, not production code: HTML + CSS only, no framework code, no prototype interactions, macOS font family names kept as is.

## Decisions

- Directory: created when missing; refused when it exists and is not empty (`Directory is not empty: <path>`), so an Agent never overwrites a project's files. Writes `index.html` and `assets/…`. Result: `{ id, directory, files: [relative paths], assets: { layerId: relativePath } , html }`.
- Root layer: `position: relative`, fixed `width`/`height` from the document (already laid out), `margin: 0 auto` not added.
- Every element: `box-sizing: border-box`. Classes are slugs of layer names (`[a-z0-9-]`, fallback layer type), made unique with `-2`, `-3`…; each element also carries `data-layer-id`.
- Child of an auto layout parent (in flex flow): primary axis `fill` → `flex: 1 1 0; min-<w|h>: 0`; cross axis `fill` or parent `crossAlign: stretch` → `align-self: stretch`; groups ignore fill/stretch (as `DesignLayout`). `hug` on a frame with auto layout or a text layer → no explicit size on that axis; otherwise px size.
- Child of a frame without auto layout or of a group: `position: absolute; left; top; width; height`.
- Auto layout frame: `display: flex; flex-direction: row|column; gap; padding`, `justify-content` start→flex-start, center, end→flex-end, space-between; `align-items` start→flex-start, center, end→flex-end, stretch.
- Hidden layers are omitted. `fill` → `background`; ellipse → `border-radius: 50%`; `cornerRadius` (frame/rectangle/image) → `border-radius`; stroke (drawn inside, above children) → `outline: Wpx solid C; outline-offset: -Wpx`; `opacity` ≠ 1; frame `clipsContent` and image → `overflow: hidden`.
- Text: `<div>` with escaped content, `white-space: pre` for `width-and-height`, else `pre-wrap`; `font-family: "<family>", -apple-system, BlinkMacSystemFont, sans-serif` (nil family → system stack only), `font-size`, `font-weight`, `line-height` (multiplier or `normal`), `color`, `text-align`.
- Image: `<img src="assets/<class>.<png|jpg|svg>" alt="<name>">`, `object-fit` fill→cover, fit→contain, stretch→fill; extension by bytes (PNG signature, JPEG `FF D8`, else SVG via `DesignJSON.isSVG`).
- Icon: `<span role="img" aria-label="<name>">` with `background-color: <icon color>` and `mask: url(assets/icons/<library>-<name>.<svg|png>) center / contain no-repeat` (plus `-webkit-mask`); one file per icon name. Bundled icons → SVG from `IconCatalog`; SF Symbols → PNG at 3× from the App closure; icon with no artwork → error `No artwork for icon <name>`.
- Colors with alpha → `rgba()`; otherwise `#RRGGBB`.

## Review Focus

- A layer name in Chinese or with symbols → class still valid and unique (slug falls back to type).
- Text containing `<`, `&`, quotes, newlines → escaped, newlines kept by `pre-wrap`.
- Exporting a non-frame (a single text or image layer) → still a valid page.
- Same icon used twice → one asset file.
- Directory exists with files → refused before writing anything.

---

### Task 1: `DesignHTML` in FudehandCore

**Files:** Create `native/Sources/FudehandCore/DesignHTML.swift`; Test `native/Tests/FudehandCoreTests/DesignHTMLTests.swift`

**Interfaces — Produces:**
- `public struct DesignHTMLExport { public var html: String; public var files: [String: Data] /* relative path → bytes, includes "index.html" */; public var assets: [String: String] /* layer id → relative path */ }`
- `public enum DesignHTML { public static func export(_ node: DesignNode, iconArtwork: (String) -> (data: Data, ext: String)? = DesignHTML.bundledIcon) throws -> DesignHTMLExport }`

- [ ] Tests (one per rule in Decisions): flex mapping for each `align`/`crossAlign`; fill/hug/fixed per axis; absolute children of a plain frame and group; hidden omitted; text escaping and font stack; image extension + object-fit; icon mask + single file for a repeated icon + SF via closure; stroke outline; ellipse; class slug uniqueness and non-ASCII fallback; missing icon artwork error.
- [ ] Run `swift test --package-path native --filter FudehandCoreTests.DesignHTMLTests` → fails, implement, → passes. Commit.

### Task 2: Store, control command, menus, tool

**Files:** `ControlProtocol.swift` (`case exportHTML(String, directory: String)`, command `export_html`), `ControlCommands.swift`, `FudehandStore.swift` (`func exportHTML(_ id: String, to directory: URL) throws -> DesignHTMLExport`, `func exportHTMLWithPanel()`), `FudehandApp.swift` (File menu "Export as HTML…" ⌘⇧E, enabled with exactly one selected layer), `LayersPanel.swift` (context menu item), `IconLayer.swift` or store (SF Symbol PNG closure), four `Localizable.strings`, `scripts/fudehand-tools.mjs` (`design_export_html`, resolves `directory`), `ChatMessages.swift` (tool label).
**Tests:** `ControlProtocolTests` (parses; missing id/directory rejected), `StoreTests` (writes files; non-empty directory refused; unknown layer), `tests/control-tools.test.ts` (listed, forwards with resolved directory).

- [ ] Write failing tests, implement, run `pnpm test:native` and `pnpm check`. Commit.

### Task 3: Docs and evidence

- [ ] `docs/agent-tools.md` coverage row; `docs/macos.md` menu entry; README section "From prototype to front-end code"; `GLOSSARY.md` term if needed; CHANGELOG entry if the project keeps an Unreleased section.
- [ ] Export a sample frame in the real app, open `index.html` in a browser, compare with `design_snapshot`; screenshots (light and dark menu) to `docs/evidence/`.
- [ ] Update #202 body to option A. Commit.
