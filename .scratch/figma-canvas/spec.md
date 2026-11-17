# Figma-Style Canvas Interaction (Native macOS)

Status: Spec pending review
Date: 2026-11-06
Scope: native App only (`native/`). The browser-compatible `apps/atlas` stays as is.

## Goals

Users report that the native canvas feels "far from smooth". All four kinds of problems must be solved:

1. Panning and zooming stutter;
2. Entering and exiting interaction mode is cumbersome;
3. Selecting and dragging frames is awkward (only the title can be dragged, no marquee selection or multi-select, no snapping, no undo);
4. The shortcuts and transition animations Figma users expect are missing.

Success criteria: interaction closely matches Figma's design mode; after a three-frame web project loads, panning and pinching show no noticeable dropped frames; web pages can be operated without an explicit "interaction mode"; every new behavior has an automated test or a real-App acceptance record.

Non-goals: reworking the browser version; resizing frames; distance annotations between frames; multiple web projects on screen at once; changing the `catalog.json` format.

## 1. Interaction Model

### Pointer

| Action | Result |
|---|---|
| Click an unselected frame (title or content) | Selects it and shows a blue selection outline. This click is not passed to the web page |
| Click the content of a selected frame (only when it is the sole selection) | Goes straight to the web page (clicks, typing, text selection). This frame is called the "active frame" |
| Drag anywhere on an unselected frame | Moves the frame (starts after a 3pt threshold); if it is part of a multi-selection, they move together |
| Drag the title bar of a selected frame | Moves the frame / the whole selection |
| Drag on empty canvas | Marquee selection (frames intersecting the rectangle are selected); holding Shift adds to the existing selection |
| Shift + click a frame | Adds it to or removes it from the selection |
| Click empty space / Esc | Clears the selection. In the active frame, Esc goes to the web page first (via the existing injected bridge); if the page does not handle it and no dialog is open, the selection is cleared |
| Hover an unselected frame | Shows a thin outline |

With a multi-selection (≥2), frame content does not receive web input; clicking one frame's content (without Shift) collapses the selection to that frame, but that click is still not passed to the web page.

Frames that are loading or have failed can be selected and moved, but never become the active frame receiving web input; the Reload (重新加载) and Open in Browser (在浏览器打开) buttons are always clickable.

### Navigation (available in any state)

- Space + drag, middle-button drag, and dragging with the hand tool **H**: pan. **V** returns to the move tool (default). The current tool is shown in the UI by a segmented control in the toolbar.
- Scroll wheel / trackpad scrolling: starting inside the active frame's content → the web page scrolls; otherwise the canvas pans. **Each gesture locks its target**: the pointer position at `phase == .began` decides the target, which holds until the gesture and its momentum end; discrete wheel events without a phase are decided per event.
- ⌘ + scroll wheel (or ⌃ + scroll wheel) and trackpad pinch: zoom anchored at the pointer, controlling the canvas from anywhere (including over the active frame).
- Zoom range 5%–400%.

### Shortcuts

When the canvas has keyboard focus:

| Key | Action |
|---|---|
| Shift+1 | Fit All (适应全部) (animated) |
| Shift+2 | Zoom to selection (animated; same as Fit All when nothing is selected) |
| Shift+0 | 100%, anchored at the canvas center (animated) |
| V / H | Move tool / hand tool |
| Arrow keys / Shift+arrow keys | Move the selection by 10 / 100 |
| Return | With a sole selection, hand keyboard focus to that frame's web page |
| Esc | Clear the selection |
| ⌘A | Select all frames |

Menu commands (available with any focus; existing commands kept and extended): ⌘0 Fit All, ⌘1 100%, ⌘+ / ⌘− zoom, ⌘R Reload. ⌘Z / ⇧⌘Z: with canvas focus, undo / redo frame moves; when the active frame's web page has focus, they go to the web page (text undo).

### Animation

Fit All, zoom to selection, focus frame (the type buttons in the bottom dock), the toolbar zoom buttons, and the shortcuts above transition over 200ms ease-out; zoom is interpolated in log space, and pan stays consistent with the zoom anchor. Any new pointer, scroll, pinch, or keyboard navigation input interrupts the animation immediately and continues from the current interpolated state.

### Snapping

While dragging frames, the bounding rectangle of the moving set is compared with the left/center/right and top/middle/bottom edges of the other unselected frames, with a threshold of 6 screen pixels (converted to world units as `6 / scale`). Each axis takes the single nearest snap and shows a red guide (spanning both related rectangles). Holding ⌃ while dragging turns snapping off. Arrow-key moves do not snap.

### Removed

- The Enter Interaction (进入交互) / Exit Interaction (退出交互) title button, the Interacting (正在交互) banner at the top, double-clicking content to enter interaction, and ⇧⌘Return;
- Double-clicking the title to focus changes to: double-clicking a frame title = zoom to that frame (animated); this is kept.

## 2. Architecture and Data Flow

### AtlasCore (pure logic, unit-testable)

- `CanvasInteraction`: pointer state machine. States: `idle`, `pressed(target, start)` (within the threshold), `movingFrames(ids, origins, start)`, `marquee(start, current, base selection)`, `panning(start, viewport)`. Inputs: down / drag / up events (screen coordinates, modifiers, button type, hit result: empty / frame content / frame title / control), the current selection, the current tool. Outputs: the new state and a list of effects (`select(Set)`, `activate(id)`, `forwardToPage`, `moveFrames([id: Point])`, `marqueeRect(Rect?)`, `pan(Viewport)`, `commitMove(from:to:)`, `guides([Guide])`).
- `Snapping`: `snap(moving: Rect, others: [Rect], threshold: Double) -> (offset: Point, guides: [Guide])`.
- `ViewportAnimation`: `value(from:to:progress:)`, ease-out, scale interpolated in log space, with the same screen anchor kept consistent.
- `ScrollRouting`: returns `page` or `canvas` from phase / momentumPhase and the hit result, and holds the locked target per gesture.
- `CanvasGeometry`: `minScale = 0.05`, `maxScale = 4`; zoom to selection reuses `fitRects`, with the result capped at 100% (consistent with the existing focus behavior); adds rectangle intersection and bounding-rectangle helpers.

### AtlasApp (AppKit)

`NativeCanvas.swift` (596 lines) is split into:

- `NativeCanvas.swift`: the `NSViewRepresentable` bridge; it issues commands only when a token changes.
- `CanvasView.swift`: the input entry point, **holding the live viewport, positions, selection, and tool**; converts NSEvent into `CanvasInteraction` events and executes the effects; keyboard shortcuts; undo registration; the animation driver (CVDisplayLink or `NSView.displayLink` (macOS 14)).
- `PreviewFrameView.swift`: responsible only for the WKWebView, loading/failed states, the Esc bridge, the navigation policy, and the Open in Browser / Reload controls. It no longer draws the selected state and has no interaction button. Whether it receives web input is decided by `CanvasView`'s hit testing (`hitTest` returns the webView subtree only when "it is the active frame and not space / hand tool / middle button").
- `CanvasOverlay.swift`: screen-space CAShapeLayers: hover outline, selection outline, active-frame outline, marquee rectangle, snapping guides.
- `CanvasGrid.swift`: a single CALayer using a tiled pattern (dot grid); panning only changes the pattern phase, and it is hidden when the dot spacing is < 8pt.

### Data Flow

- Panning and zooming do not go through SwiftUI. `CanvasView` calls back `onViewportSettled(Viewport)` when things "settle" (gesture ended, 150ms idle, animation finished); frame moves call back `onFramesMoved([String: Point])` at drag end / arrow keys / undo and redo; selection changes call back `onSelectionChange(Set<String>)`. `AtlasStore` keeps debouncing layout saves.
- The toolbar zoom percentage comes from a separate `ZoomIndicator: ObservableObject`, which `CanvasView` updates at ≤30Hz; only the toolbar observes it, so the canvas does not redraw because of it.
- Store → canvas becomes one-shot commands: `ViewportRequest(target: Viewport, animated: Bool, token: Int)` (Fit All, focus, zoom, Restore Default Layout (恢复默认布局)), `reloadToken`, project switching, and `positionsToken` (replaces all positions when restoring the default layout). `updateNSView` acts only when a token or the project changes.
- `AtlasStore.interactingFrameID` is deleted; replaced by `selection: Set<String>` (reported back by the canvas, used by Shift+2 and menu availability). "Active frame" = sole selection.

### Rendering

- Pan: change the world view's `bounds.origin` without triggering web page relayout; turn off CA implicit animations (`CATransaction.setDisableActions(true)`).
- While a zoom gesture is in progress (pinch, continuous ⌘ scroll-wheel events, animation): only set `sublayerTransform` on the world layer (GPU scaling), and on settling commit the accumulated transform as a `bounds` scale, at which point WebKit redraws sharply. The web page may look briefly blurry during the gesture (consistent with Figma).
- To verify by measurement: if a noticeable flicker appears on commit, fall back to committing about every 100ms during the gesture.

### Undo

Use the window's `NSUndoManager`. One drag, one arrow-key move, and one multi-selection move are each one step, with the action name Move Frame (移动画框). Undo/redo restores positions and calls back `onFramesMoved`. Switching web projects, restoring the default layout, and re-reading the directory clear the undo actions registered by this canvas.

## 3. Error Handling and Edge Cases

- When the window loses focus or the App becomes inactive: clear the held-space, pan, and marquee states; an in-progress frame drag is committed at its current position as one undo step and called back.
- Switching web projects: clear the selection, undo history, and in-progress animations. Reloading the web page keeps the selection.
- Keyboard routing: when the web page has focus, letters, digits, and arrow keys go to the web page; Shift+digit and V/H take effect only when the canvas has focus. ⌘ menu commands are always available; ⌘Z/⇧⌘Z are routed by focus (see above).
- Accessibility: a frame's accessibility label includes the Selected (已选中) / Active (活动) state; the canvas help text and the bottom hint are updated to "Click a frame to work with it directly · Space-drag to pan · ⌘-scroll or pinch to zoom · Shift+1 to fit all" (点选画框后可直接操作 · 空格拖动平移 · ⌘滚轮或捏合缩放 · Shift+1 适应全部).

## 4. Testing and Acceptance

TDD: write a failing test first, then implement.

AtlasCore unit tests:

- State machine: clicking an unselected frame only selects and does not forward; clicking the content of the sole selected frame forwards to the web page; no move within the 3pt threshold; Shift adds to / removes from the selection; marquee intersection hits and Shift accumulation; multi-selection moves together; hand tool / space / middle-button pan; drag end produces exactly one `commitMove`.
- Snapping: left/center/right and top/middle/bottom alignment, threshold converted with zoom, nearest candidate wins, ⌃ disables it, zero offset with no candidate.
- Scroll routing: locks at began, holds during momentum, discrete wheel decided per event, always canvas with the ⌘ modifier.
- Animation interpolation: endpoints, ease-out monotonic, scale interpolated in log space, continues from the current value after interruption.
- Zoom range 5%–400%.

AtlasAppTests: the store updates viewport and saves only on the settle callback; the `ViewportRequest` token increments; after undo / redo of a move, positions match what is saved; switching web projects clears the selection.

The existing `pnpm test:native` and `pnpm check` must keep passing.

Real-App acceptance (recorded in `docs/native-verification.md`):

- After a three-frame web project loads, pan and pinch continuously; use the debug switch `UI_ATLAS_FRAME_LOG=1` to log frame intervals and compare the number of dropped frames (>25ms) before and after the rework;
- Clicking an unselected frame does not trigger a web page action, and clicking again operates the web page; scrolling inside the active frame scrolls the web page, outside it pans;
- Marquee selection, Shift multi-select, moving together, snapping guides, ⌘Z / ⇧⌘Z;
- Shift+1 / Shift+2 / Shift+0 animations and interruption;
- Light, dark, and a narrower window.

Docs: update the canvas operations in `docs/macos.md`, `GLOSSARY.md` ("interaction mode" changes to "active frame"), and the in-App hint text.

## Delivery

This repository has no remote: commit locally on the `claude/figma-canvas-interaction` branch; do not create a PR/CI.
