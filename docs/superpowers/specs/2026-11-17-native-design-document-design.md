# Native Design Document and Figma-Style Workflow (#46)

Date: 2026-11-17. Source: Issue #46. The user issued this via `/goal` and asked for autonomous progress; items in this document marked "implementer decides" are trade-offs the implementer made according to the issue's intent, without separate confirmation.

## Intent

ui-atlas changes from "showing web projects on a canvas" to "a native AI design tool": the canvas holds layer data, agents and people edit the same design document, the canvas renders natively in real time, and designs are saved as ui-atlas's own project files. The goal is to remove the heavy pipeline of one front-end project per web project with resident Node/Vite/WebKit processes, and to let agents create and modify interface elements directly instead of editing web source code.

## Goals

- The design document is a tree of layers: frame, rectangle, ellipse, text, image, group; frames support auto layout; all layers support fill, stroke, corner radius (for applicable types), opacity, show/hide, and lock.
- The canvas renders layer data directly; any change is visible immediately, with no compilation and no dependency on Node or a web server.
- Agents use MCP tools to read the document structure, add/delete/modify nodes, and take screenshots to check; all changes go to the App through the control channel, and the App is the sole owner of document state.
- Manual editing: layers panel (hierarchy, show/hide, lock, rename), properties panel (position, size, fill, stroke, text, auto layout); layers can be selected, moved, and resized on the canvas.
- Project files: New, Open, Save, Save As; the format is public JSON with a version number. The App starts with a blank document.
- Undo/redo covers both manual and agent edits, sharing one history.
- Remove the web-project pipeline: `WKWebView` frames, the Node preview launcher, `catalog.json`, `examples/`.

## Non-goals

Same as the issue: no Figma interoperability, no multiplayer collaboration, prototyping interactions, components/variants/variables, or code generation, and no retention of web projects. Also out of scope this round: rotation, gradients and multiple fills, shadows and blur, vector paths and boolean operations, editing text directly on the canvas (text is edited in the properties panel), and drag-to-reorder of auto layout children (use the layers panel or an agent to adjust order).

## Anti-goals

- Agent changes require restarting the App, reloading, or compiling to become visible — that would be the same as not doing it.
- A second owner of document state appears (for example, the Node side caching a copy of the document and writing it back), causing manual and agent changes to overwrite each other.
- Panning and zooming visibly drop frames as the number of layers grows.

## Approach

Options considered:

1. **Core Animation layer tree (adopted)**: each design node maps to a `CALayer` (`CAShapeLayer` for shapes, `CATextLayer` for text, `contents` for images), updated incrementally by node id. Panning and zooming keep the existing canvas's `world.bounds` and GPU transform; vectors and backgrounds are rendered by Core Animation at any zoom; text and images update `contentsScale` to the zoom factor once zoom settles. Screenshots use the same build functions with offscreen `render(in:)`.
2. **A single NSView redrawn entirely with Core Graphics**: simplest to implement, but every pan/zoom and every change redraws all nodes, making it hard to stay smooth beyond 100 layers.
3. **SwiftUI `Canvas` or a SwiftUI view tree**: disconnected from the existing AppKit canvas (input routing, viewport animation, marquee selection), requires rewriting the interaction layer, with no obvious benefit.

Where document state lives:

- **Owned by the App (adopted)**: a pure Swift document model and editor in `AtlasCore`, with the App's `AtlasStore` holding the only instance; agents send commands through the control channel. This matches the issue's "the App is the sole owner of document state".
- Node side owns the document and the App only renders: there would be two owners, which the issue rules out.

## Design

### Document format (`AtlasCore/DesignDocument.swift`)

Extension `.uiatlas`, content is UTF-8 JSON:

```json
{
  "format": "ui-atlas.design",
  "version": 1,
  "nodes": [
    { "id": "screen", "type": "frame", "name": "Home", "x": 0, "y": 0, "width": 390, "height": 844,
      "fill": "#FFFFFF", "cornerRadius": 0, "clipsContent": true,
      "layout": { "direction": "vertical", "spacing": 12, "padding": { "top": 16, "right": 16, "bottom": 16, "left": 16 },
                  "align": "start", "crossAlign": "stretch" },
      "children": [
        { "id": "title", "type": "text", "name": "Title", "x": 16, "y": 16, "width": 120, "height": 28,
          "text": { "content": "Today's plan", "fontSize": 22, "fontWeight": 600, "color": "#111111", "align": "left", "autoResize": "height" },
          "sizing": { "horizontal": "fill", "vertical": "hug" } }
      ] }
  ]
}
```

- All coordinates are relative to the parent node, in points; top-level nodes are relative to the canvas origin. Array order is stacking order, with later items on top.
- Common fields: `id` (unique within the document), `type`, `name`, `x`, `y`, `width`, `height`, `visible` (default true), `locked` (default false), `opacity` (0–1, default 1), `fill` (`#RRGGBB` or `#RRGGBBAA`; omit for no fill), `stroke` (`{color, width}`, optional), `sizing` (`{horizontal, vertical}`, values `fixed`/`hug`/`fill`, default fixed).
- `cornerRadius`: frame, rectangle, image. `clipsContent`: frame (default true). `children`: frame, group.
- `text`: `content`, `fontSize`, `fontWeight` (100–900), `fontFamily` (optional; system font if omitted), `color`, `align` (left/center/right), `lineHeight` (optional, a multiplier), `autoResize` (`none`/`height`/`width-and-height`).
- `image`: `data` (base64 PNG or JPEG) and `fit` (`fill`/`fit`/`stretch`).
- `layout` (frame): `direction` (horizontal/vertical), `spacing`, `padding`, `align` (main axis start/center/end/space-between), `crossAlign` (start/center/end/stretch).
- Validation on read: `format` must match; a `version` greater than the currently supported version is rejected with "file was created by a newer version of ui-atlas" (文件由更新版本的 ui-atlas 创建); duplicate ids, type/field mismatches, non-finite values, and negative sizes are all reported with the specific path. Writes use sorted keys and two-space indentation for easy diffing.

### Layout (`AtlasCore/DesignLayout.swift`)

Layout results are written straight back to the nodes' `x/y/width/height` (as in Figma, the file stores computed geometry), and the renderer reads only these values. After every edit the whole document is re-laid out once; text sizes come from a measurement function injected by the App (`AtlasCore` does not depend on AppKit):

1. Bottom-up: text is measured according to `autoResize`; `hug` auto layout frames compute their size from child sizes, spacing, and padding; groups shrink to the union of their children (the group origin moves to the top-left of the union and children shift accordingly).
2. Top-down: auto layout frames distribute `fill` child sizes along the main axis, set `stretch`/`fill` on the cross axis to the content area size, then place children according to `align`; then recurse into children.
3. Width changes affect the height of `autoResize: height` text, so the whole process runs twice.

In parents that do not use auto layout, children with `fill` and `hug` (other than text and auto layout frames) are treated as fixed.

### Editor and undo (`AtlasCore/DesignEditor.swift`)

`DesignEditor` is a value type holding the document and history snapshots:

- `perform(_ name:, change:)`: records a snapshot before the change, applies the change, and re-lays out; if the document changed, pushes onto the undo stack and clears the redo stack. One agent command (including creating an entire subtree at once) is one undo step.
- Canvas drags and resize handles: `beginGesture()` records a snapshot, the document is modified without recording during the gesture, and `endGesture(name:)` pushes one step.
- Continuous adjustments in the properties panel (such as the color picker) carry a coalescing key; consecutive changes with the same key are merged into one step.
- Node operations: insert (may include nested children; generates an 8-character random id when none is given), update by patch (nested objects merged field by field), delete, move/reparent (keeping the absolute position on the canvas), set visible/locked.
- Tracks a revision number; on save, the saved revision is recorded and used for the "Edited" (已编辑) indicator.

### Control channel and MCP tools

The control protocol (newline-delimited JSON, keeping the existing socket and security constraints) replaces its commands with:

| Command | Purpose |
| --- | --- |
| `get_state` | File name, path, whether edited, selection, viewport, whether undo/redo is available, summary of top-level nodes |
| `get_document` | Full layer tree; image data is replaced by `"<N bytes>"` |
| `get_node` | Subtree of a single node |
| `create_node` | `{parent?, index?, node}`; `node` may contain nested `children`; returns the new id |
| `update_node` | `{id, changes}`, a partial field patch |
| `delete_nodes` | `{ids}` |
| `move_node` | `{id, parent?, index?}`; `parent` of null means top level |
| `select` | `{ids}` |
| `undo` / `redo` | Undo or redo one step |
| `new_document` / `open_document` / `save_document` | New (refused when there are unsaved changes unless `discard: true`), open `{path}`, save `{path?}` |
| `focus_node` / `fit_all` / `zoom` | Viewport |
| `node_snapshot` | `{id, scale?}`; returns a PNG of that node's rendering |

Field validation exists in only one place in Swift (`AtlasCore/DesignJSON.swift`, shared by file reading and agent patches). `scripts/atlas-tools.mjs` only forwards arguments to the control channel; MCP tool names are `design_*` and `canvas_*`; images may be given as `image.path` (a local file path), which the Node side reads into base64 `image.data` before forwarding. The harness's system prompt changes to a design assistant.

### App

- `AtlasStore` holds the `DesignEditor`, the current file URL, the selection, and viewport requests; on launch it creates a blank document and does not start any Node process (the chat panel starts the harness on demand only when a message is sent).
- `DesignRenderer` syncs the document to a `CALayer` tree, reusing layers by id and updating only changed properties; hidden nodes are not rendered; frames with `clipsContent` clip their sublayers.
- Canvas interaction (Figma-style):
  - Clicking selects a direct child inside a top-level frame; clicking a frame's name label or empty area of a frame selects the frame; clicking a group selects the whole group, and double-clicking enters the next level; ⌘ + click selects the deepest layer. Locked and hidden layers cannot be clicked on the canvas.
  - Dragging moves selected layers (3pt threshold, snapping to sibling layer edges and center lines, ⌃ disables snapping); children inside auto layout frames do not move when dragged.
  - With a single selection, 8 resize handles are shown; dragging changes the size and sets the corresponding direction to fixed.
  - Dragging on empty space performs marquee selection of top-level layers; Shift adds to the selection.
  - Tools: Move V, Hand H, Frame F, Rectangle R, Ellipse O, Text T; creation tools drag out a size on the canvas (a single click uses the default size), the new layer lands inside the top-level frame containing the start point, and the tool returns to Move after creation.
  - Keyboard: arrow keys move by 1, Shift + arrow keys move by 10; Delete/Backspace deletes; Esc selects the parent layer, or clears the selection when there is no parent; ⌘A selects everything at the current level; pan and zoom keep the existing rules.
- Layers panel (left sidebar): indented tree, type icons, double-click to rename, eye and lock buttons, click to select, ⌘/Shift for multiple selection, synced with the canvas selection.
- The right-hand inspector has two tabs, Design (设计) / Chat (对话). Design tab: with nothing selected, shows document info; with a single selection, shows name, X/Y/W/H, sizing mode, opacity, corner radius, fill, stroke, text, auto layout, clip content, image fit mode, and replace image; with multiple selection, shows the count and opacity.
- Menus: File (文件) (New (新建) ⌘N, Open (打开) ⌘O, Save (保存) ⌘S, Save As (另存为) ⇧⌘S), Edit (编辑) (Undo (撤销) ⌘Z, Redo (重做) ⇧⌘Z; when a text field has focus, these go to the text field), Canvas (画布) (zoom). On New, Open, or Quit with unsaved changes, the App asks whether to save.
- The window title shows the file name, with "Edited" when unsaved.

### Removal

Delete `PreviewFrameView`, `PreviewSession`, `FramePageScripts`, `ThumbnailCache`, `Catalog`, `LayoutStore`, `ScrollRouting` (scrolling always pans the canvas), `SidebarOrdering`, `FrameConsole`, as well as `scripts/launcher.mjs`, `native-preview.mjs`, `preview-gate.*`, `catalog.json`, `tests/fixtures/catalog-conformance.json`, `examples/`, and the corresponding tests. `pnpm check` changes to run only Vitest (there are no longer examples to type-check and build). `native-build.mjs` still writes `workspace.json` so the chat panel can find the harness and Node.

## Left to the implementer

- Control styles, icons, default colors, and default sizes.
- Detailed alignment between text measurement and `CATextLayer` rendering.
- Edge cases in auto layout (for example, fill children inside a hug parent are treated as fixed).

## Acceptance

See the acceptance criteria in Issue #46; in addition:

- `AtlasCore` unit tests cover document read/write and version validation, patch validation, layout, editing and undo, and the canvas interaction state machine.
- `AtlasApp` tests cover control command dispatch, incremental renderer updates, and screenshots.
- Node tests cover MCP tool forwarding and `image.path` reading.
- In the real App, build a mobile frame step by step with MCP tools, and put light and dark screenshots in `docs/evidence/`.
