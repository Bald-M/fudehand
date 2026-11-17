# macOS Usage Guide

ui-atlas is a native SwiftUI/AppKit design tool. The canvas renders the layers of the design document directly with Core Animation and does not depend on a web server (see [ADR 0006](adr/0006-native-design-document.md)).

## Launching and Building

Requires macOS 14+, Swift 6+, Node.js 22.12+, and pnpm 11.7.0. Installing the Xcode Command Line Tools is enough; full Xcode is not needed, and there are no third-party Swift package dependencies.

```bash
pnpm install
pnpm dev                 # Debug build, then open the App
pnpm build:native        # Release build with local ad-hoc signing
open dist/ui-atlas.app
```

When the App starts it first shows the launch window and starts no Node processes:

- On the left, New Design Document (新建设计文档, ⌘N) opens a blank untitled document, and Open… (打开…, ⌘O) shows the open panel.
- Recent (最近打开) lists recently opened or saved project files in reverse chronological order (up to 10), showing the file name, its folder, and the time. Click an item, or select it and press Return, to open it; files that were deleted or moved are shown as unavailable, and clicking one shows a notice and offers to remove it from the list; Clear Recents (清除记录) empties the list.
- Templates (模板) lists the templates bundled with the App, and shows No Templates (暂无模板) when there are none. Clicking a template gives an untitled document that is not linked to the template file; saving asks for a location.

Once editing starts — via New, Open, a recent item, a template, opening a file from Finder, or the Agent's `new_document` / `open_document` — the editor window opens and the launch window closes; Window › Launch Window (窗口 › 启动窗口) reopens it. The editor window is not restored on quit, so the next launch shows the launch window first again. The Agent harness starts only when the chat panel sends its first message.

**UI language.** The App comes in US English, British English, Simplified Chinese, and Traditional Chinese. The first launch uses US English whatever the system language is. The app menu's Language submenu switches language: every window and the App's own menu items change immediately, the choice is saved and used at the next launch, and the system-provided menu items (About, Quit, Hide, the standard Edit and Window items) change at the next launch, as the submenu notes. Switching never changes a design document: layer names stay as they are. A layer without a name — newly created, or read from a project file that omits `name` — gets its default name in the language in use at that moment. Project-file errors (not a project file, missing or newer format version) follow the UI language wherever they are shown, including the Agent's `open_document`; the control channel's other errors (protocol, field validation, commands) are not localized.

Templates live in `native/Resources/Templates/`: put a `.uiatlas` file there and rebuild, and it appears in the Templates section, named after the file, with no code changes.

The build script writes the local source directory, the Node path, and the PATH at launch time into the App's `Contents/Resources/workspace.json`; the chat panel uses it to find `scripts/agent-chat.mjs` and Node. The canvas, layers, and project files do not depend on the source directory; if the App is copied to another machine, only the chat panel stops working.

SwiftPM build output and the module cache go to the system temporary directory by default. `UI_ATLAS_SWIFT_SCRATCH` overrides the build directory, and `UI_ATLAS_SWIFT_MODULE_CACHE` overrides the module cache directory. Do not run two Swift builds in the same scratch directory at the same time.

## Files

- File menu (文件): New ⌘N, Open ⌘O, Open Recent (打开最近), Save ⌘S, Save As ⇧⌘S. Open Recent shares one record with the launch window's Recent list (written on every successful open or save, deduplicated, moved to the top, up to 10 items), and the record can be cleared at the end of the submenu. Project files use the `.uiatlas` extension and contain versioned JSON (see the [design spec](superpowers/specs/2026-11-17-native-design-document-design.md#document-format-atlascoredesigndocumentswift) for the format).
- With unsaved changes, the window title shows Edited (已编辑); New, Open, or quitting first asks whether to save.
- Opening a malformed file, or one created by a newer version, shows the specific reason and leaves the current document unchanged.
- The App exports the `.uiatlas` file type in Info.plist (`local.ui-atlas.design`, conforming to JSON) and registers itself as its editor: after building, double-clicking in Finder, dragging onto the Dock icon, or Open With all open project files in ui-atlas. The App has only one window, so opening a file replaces the current document (asking first if there are unsaved changes).

## Canvas Interaction

Interaction follows Figma.

**Selection**

- Clicking content inside a top-level frame selects its direct child layer; clicking empty space in the frame, or the name label above the frame, selects the frame; clicking any other top-level layer selects it directly.
- When a layer is selected, clicking one of its siblings selects that sibling directly; double-clicking the selected layer selects the next child layer under the pointer; ⌘ + click selects the deepest layer directly.
- A group can only be hit through its child layers, and clicking selects the whole group. Locked or hidden layers cannot be hit on the canvas and can only be selected in the layers panel.
- Shift + click adds to or removes from the selection; dragging on empty canvas does a marquee selection of top-level layers, and Shift adds to it. Hovering shows a thin outline.
- Esc selects the parent layer, or clears the selection at the top level; Return selects the children of the selected frame or group; ⌘A selects all layers at the current level.

**Moving and Resizing**

- Drag selected layers to move them (starting after a 3pt threshold); with multiple layers selected they move together. One drag is one undo step. The position of a child layer in an auto layout frame is determined by the layout and does not follow the drag.
- While dragging, layer edges and center lines snap when within 6 screen points of a sibling layer or the parent frame, and red guides appear; hold ⌃ while dragging to turn snapping off.
- With a single selection (except groups), 8 resize handles appear; dragging one changes the size and sets the sizing mode in that direction to fixed. For text, changing the width switches it to Auto Height (自动高度), and changing the height switches it to Fixed (固定).
- Arrow keys move by 1 and Shift + arrow keys by 10, each key press being one undo step. Delete removes the selected layers.

**Creating**

- The toolbar switches tools: Move V, Hand H, Frame F, Rectangle R, Ellipse O, Text T. A creation tool drags out a size on the canvas, and a single click uses the default size (auto width and height for text); if the start point is inside a top-level frame, the new layer goes into that frame. After creating, the tool returns to Move.
- The toolbar or Canvas › Insert Image… (画布 › 插入图片…, ⇧⌘I) inserts a PNG/JPEG: when a frame is selected it goes into that frame, otherwise it is placed at the center of the viewport.

**Navigation**

- Scroll wheel or trackpad scrolling, Space + drag, middle-mouse drag, or dragging with the Hand tool pans the canvas. The cursor turns into a hand as soon as Space is pressed, and reverts on release.
- ⌘ / ⌃ + scroll wheel, or trackpad pinch, zooms anchored at the pointer, within 5%–400%.
- The toolbar provides zoom out, the zoom percentage (click to return to 100%), zoom in, and Fit All. Menu shortcuts: ⌘+ zoom in, ⌘− zoom out, ⌘1 100%, ⌘0 Fit All.
- When the canvas has focus: Shift+1 fits all, Shift+2 zooms to the selection, Shift+0 returns to 100%. Double-clicking a top-level frame's name label zooms to focus on that frame. These transitions use a 200ms animation, and new input interrupts them immediately.

**Undo**

- ⌘Z / ⇧⌘Z undo and redo changes to the design document; human and Agent changes share one history. When a text field has focus, these go to the text field. Creating or opening a file clears the history.

## Panels

- **Layers panel** (left sidebar): a hierarchy tree with upper layers first. Click to select, ⌘-click to add or remove, Shift-click to add; double-click to rename; the eye and lock buttons toggle visibility and locking; the context menu can move a layer up or down one level, bring it to the front or send it to the back, zoom to the layer, or delete it.
- **Inspector** (right side, ⌥⌘I shows or hides it): the Design (设计) tab edits the selected layer's name, position and size, sizing mode, opacity, corner radius, clip content, fill, stroke, text, auto layout, and image fit; with multiple layers selected, opacity can be changed for all of them at once. The Chat (对话) tab is the Agent chat panel (⇧⌘A).
- The appearance menu in the top right chooses Follow System, Light, or Dark.

## Verification

```bash
pnpm test:native
pnpm check
pnpm build:native
codesign --verify --deep --strict dist/ui-atlas.app
```

The Swift tests cover document reading/writing and version checks, field patches, auto layout, edit history, click-selection rules, the canvas interaction state machine, incremental renderer updates and snapshots, and control commands. The Node tests cover MCP tool forwarding, image reading, and the chat harness.

## Performance Troubleshooting

Launch the App with `UI_ATLAS_FRAME_LOG=1` and it prints one line per second to stderr, `[frame] hitches=N frames=M`, for comparing dropped frames while panning and zooming.
