# Native Design Document Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the canvas from web projects to a design document owned by the App and rendered with Core Animation, edited jointly by people and agents, and savable as a `.uiatlas` project file.

**Architecture:** `AtlasCore` adds a pure Swift document model, patch validation, layout, and an editor with history; `AtlasApp` uses `DesignRenderer` to sync the document to a CALayer tree, canvas interaction becomes layer-oriented, and SwiftUI provides the layers panel and properties panel; control channel commands become design commands, and `atlas-tools.mjs` only forwards.

**Tech Stack:** Swift 6 toolchain (Swift 5 language mode), AppKit/SwiftUI/Core Animation/CoreText, Node 22 + Vitest.

**Spec:** `docs/superpowers/specs/2026-11-17-native-design-document-design.md`

## Global Constraints

- macOS 14+, no third-party Swift packages; `AtlasCore` does not depend on AppKit.
- Document format: `"format": "ui-atlas.design"`, `"version": 1`, extension `.uiatlas`, coordinates relative to the parent node.
- UI text and error messages are in Chinese; field validation exists in only one place in Swift.
- Launch starts no Node processes; the control channel socket and permission constraints are unchanged.
- Do not run two Swift builds in the same scratch directory at once (this worktree uses `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-46-scratch`).

## Review Focus

- Opening a malformed file, a file with a higher version, or one with duplicate ids: report the specific reason and leave the current document unchanged (Task 1 tests).
- Agent patches with unknown fields, wrong types, or fields applied to a type that does not support them (such as setting `layout` on an ellipse): reject the whole command, leaving the document and history unchanged (Task 2 tests).
- Deleting a parent that contains selected children, moving a node into its own descendant: the selection is cleaned up; the move is rejected (Task 3 tests).
- New/Open/Quit with unsaved changes: ask whether to save; the agent's `new_document` without `discard` is rejected (Task 7 tests).
- Text with `autoResize: height` inside auto layout with fill width: its height updates after the width changes (Task 2 layout tests).

---

### Task 1: Document model and file read/write

**Files:** Create `native/Sources/AtlasCore/DesignDocument.swift`, `native/Tests/AtlasCoreTests/DesignDocumentTests.swift`

**Interfaces — Produces:**
- `DesignColor` (`hex: String` encoding/decoding, `r,g,b,a: Double`), `DesignStroke {color, width}`, `DesignText {content, fontSize, fontWeight, fontFamily?, color, align, lineHeight?, autoResize}`, `DesignImage {data: Data, fit}`, `AutoLayout {direction, spacing, padding: EdgeInsets, align, crossAlign}`, `Sizing {horizontal, vertical}`.
- `enum NodeType: String { frame, rectangle, ellipse, text, image, group }`, `struct DesignNode: Equatable` (all fields from the spec, `children: [DesignNode]`).
- `struct DesignDocument: Equatable { var nodes: [DesignNode]; static let formatVersion = 1; static func decode(_ data: Data) throws -> DesignDocument; func encoded() throws -> Data }`; error type `DesignError: LocalizedError { message }`.

- [ ] Tests: round-trip encoding stays equal; `version: 2` reports "file was created by a newer version of ui-atlas" (文件由更新版本的 ui-atlas 创建); wrong `format`, duplicate ids (reporting the id), and a text node missing `text` all report errors; encoded output has sorted keys.
- [ ] Implement and pass: `swift test --filter AtlasCoreTests.DesignDocumentTests`.

### Task 2: Patch validation and layout

**Files:** Create `AtlasCore/DesignPatch.swift`, `AtlasCore/DesignLayout.swift`, tests `DesignPatchTests.swift`, `DesignLayoutTests.swift`

**Interfaces — Produces:**
- `DesignPatch.node(from json: [String: Any], defaultType:) throws -> DesignNode` (creation, including nested children and defaults); `DesignPatch.apply(_ changes: [String: Any], to node: inout DesignNode) throws` (nested objects merged field by field, `null` clears optional fields); `DesignPatch.json(_ node:, includeImageData: Bool) -> [String: Any]`.
- `typealias TextMeasure = (DesignText, _ maxWidth: Double?) -> Size`; `DesignLayout.apply(to nodes: inout [DesignNode], measure: TextMeasure)`.

- [ ] Patch tests: unknown field reports "unsupported field: foo" (不支持字段：foo); `opacity: 2` reports a range error; setting `layout` on an ellipse is rejected; `text: {fontSize: 20}` changes only the font size; `fill: null` clears it.
- [ ] Layout tests: a vertical hug frame (padding 16, spacing 12, two children 50 tall) has height 144; fill children split the remaining width evenly; crossAlign stretch; space-between; groups shrink to the union of their children with a normalized origin; fill-width text with `autoResize: height` changes height after the parent width changes (the measure function returns line count by width).
- [ ] Implement and pass.

### Task 3: Editor and history

**Files:** Create `AtlasCore/DesignEditor.swift`, test `DesignEditorTests.swift`

**Interfaces — Produces:** `struct DesignEditor { var document; var revision: Int; var canUndo/canRedo; init(document:, measure:); mutating func perform<T>(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> T) rethrows -> T; beginGesture(); endGesture(_ name:); undo() -> Bool; redo() -> Bool; func node(_ id:) -> DesignNode?; func parentID(of:) -> String??; func worldRect(_ id:) -> Rect?; func path(to id:) -> [String] }`; `extension DesignDocument { mutating func insert(_ node:, parent: String?, index: Int?) throws; update(_ id:, _ change: (inout DesignNode) throws -> Void) throws; delete(_ ids: Set<String>); move(_ id:, parent: String?, index: Int?) throws; func allIDs() -> Set<String>; static func newID(existing:) -> String }`.

- [ ] Tests: one perform is one undo step, redo restores, a new operation clears redo; no change means nothing is pushed; the same coalescing key merges; a gesture begin/end is one step; moving into its own descendant errors; reparenting keeps world coordinates; revision increments.
- [ ] Implement and pass.

### Task 4: Control protocol and interaction state machine

**Files:** Modify `AtlasCore/ControlProtocol.swift`, `AtlasCore/CanvasInteraction.swift`; delete `Catalog.swift`, `LayoutStore.swift`, `ScrollRouting.swift`, `SidebarOrdering.swift`, `FrameConsole.swift` and their tests; update `ControlProtocolTests`, `CanvasInteractionTests`

**Interfaces — Produces:**
- `ControlCommand`: `getState, getDocument, getNode(String), createNode(parent: String?, index: Int?, node: JSONObject), updateNode(String, JSONObject), deleteNodes([String]), moveNode(String, parent: String?, index: Int?), select([String]), undo, redo, newDocument(discard: Bool), openDocument(String), saveDocument(String?), focusNode(String), fitAll, zoom(Double), nodeSnapshot(String, scale: Double)`; `JSONObject` is a `Sendable` wrapper around `[String: Any]` (stored as JSON Data to make Equatable easy).
- `HitTarget: empty | node(String) | label(String) | handle(String, ResizeHandle)`; `CanvasTool: move, hand, frame, rectangle, ellipse, text`; new effects `resize(id, Rect)`, `commitResize(id)`, `create(NodeType, Rect, parent: String?)`, `beginGesture`; `InteractionContext.frames` renamed to `rects`, adding `movable: Set<String>`.

- [ ] Protocol tests: each new command parses, plus missing-argument and type errors; interaction tests: dragging a handle emits resize, a creation tool drags out a rectangle, dragging an immovable child does not move it.
- [ ] Implement and pass AtlasCoreTests in `pnpm test:native`.

### Task 5: Renderer and canvas

**Files:** Create `AtlasApp/DesignRenderer.swift`, `AtlasApp/TextMetrics.swift`; rewrite `CanvasView.swift`, `CanvasOverlay.swift`, `NativeCanvas.swift`; delete `PreviewFrameView.swift`, `FramePageScripts.swift`, `ThumbnailCache.swift`, `PreviewSession.swift`; tests `DesignRendererTests.swift`, rewrite `CanvasInputTests.swift`

**Interfaces — Produces:** `final class DesignRenderer { let root: CALayer; func sync(_ nodes: [DesignNode]); func updateScale(_ zoom: Double); static func snapshotPNG(_ node: DesignNode, scale: Double) throws -> Data }`; `TextMetrics.measure: TextMeasure`; `AtlasCanvasView.update(document:revision:selection:viewportRequest:tool:)`, callbacks `onSelect(Set<String>)`, `onEdit(DesignEdit)` (`.move([id: Point]) / .resize(id, Rect) / .create(...) / .delete / .beginGesture / .endGesture(String)`).

- [ ] Tests: after sync the layer count equals the visible node count; changing one node only replaces its properties and reuses the layer object; hidden nodes have no layer; snapshot size = node size × scale; end-to-end input tests for canvas click/drag/handles/creation.
- [ ] Implement and pass.

### Task 6: Store, panels, menus, files

**Files:** Rewrite `AtlasStore.swift`, `WorkspaceView.swift`, `AtlasApp.swift`, `ControlCommands.swift`; create `LayersPanel.swift`, `InspectorPanel.swift`; modify the root source of `ChatSession`/`ChatPanel`; tests `StoreTests`, `ControlCommandTests`

- [ ] Tests: after launch the document is empty with no child processes; control commands create/update/undo/redo/save/open round-trip; dirty flag; `new_document` with unsaved changes and no discard errors; opening a bad file keeps the original document.
- [ ] Implement and pass `pnpm test:native`.

### Task 7: MCP tools and removing the web pipeline

**Files:** Rewrite `scripts/atlas-tools.mjs`, `scripts/agent-chat.mjs` (system prompt), tests `atlas-tools.test.ts`, `control-tools.test.ts`, `mcp-server.test.ts`; delete `scripts/launcher.mjs`, `native-preview.mjs`, `preview-gate.*`, `catalog.json`, `examples/`, `tests/launcher*.ts`, `tests/native-launcher.test.ts`, `tests/catalog-conformance.test.ts`, `tests/preview-gate.test.ts`, fixture; change `package.json` check to `vitest run`; delete `pnpm-workspace.yaml` and update the lockfile.

- [ ] Tests: each design tool forwards its arguments as the corresponding control command; `imagePath` is read into base64; when the App is not running, reports "ui-atlas is not running" (ui-atlas 未运行).
- [ ] Implement and pass `pnpm check`.

### Task 8: Documentation and acceptance

- [ ] Update `GLOSSARY.md`, `docs/macos.md`, `README.md`, `CLAUDE.md`, `docs/agents/*`.
- [ ] Real App: build via MCP a mobile frame with a navigation bar, a card list, and a button; agent reads back after panel edits; undo/redo; save-close-open is consistent; pan and zoom with 150 layers under `UI_ATLAS_FRAME_LOG=1`; light/dark screenshots into `docs/evidence/`.
