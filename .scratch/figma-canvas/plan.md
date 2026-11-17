# Figma-Style Canvas Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the native macOS canvas to Figma-style "select first, then operate" interaction, and eliminate pan/zoom stutter.

**Architecture:** Input, snapping, scroll routing, and viewport animation are extracted into pure `AtlasCore` logic, with tests written first; the AppKit `CanvasView` holds the live viewport, positions, and selection, and syncs them to the SwiftUI `AtlasStore` only when things "settle"; the grid and overlay switch to CALayer, and zoom gestures use a layer transform, committing bounds only after settling.

**Tech Stack:** Swift 6 toolchain (language mode v5), SwiftUI + AppKit + WebKit, Swift Testing, macOS 14+, no third-party dependencies.

**Spec:** `.scratch/figma-canvas/spec.md`

## Global Constraints

- Change only `native/` and docs; leave `apps/atlas`, `examples/`, and the `catalog.json` format untouched.
- macOS 14 deployment target, `swiftLanguageModes: [.v5]`, no Swift package dependencies.
- UI text is Simplified Chinese; new text follows the spec wording exactly.
- Zoom range `minScale = 0.05`, `maxScale = 4`; Fit All (适应全部) / zoom to selection / focus results are capped at 100%.
- Drag threshold 3 screen points; snapping threshold 6 screen points (world units `6 / scale`); animation 200ms ease-out; settle detection after 150ms idle; zoom indicator ≤30Hz.
- Arrow keys move 10, Shift+arrow keys 100; arrow keys do not snap.
- At the end of each task `pnpm test:native` is all green; commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; `git add` only this task's files.
- Quick single-test run: `swift test --package-path native --disable-sandbox --filter <TestName>`.

## Review Focus

1. Clicking content while a selected frame is loading or has failed (webView hidden) → must not hand the event to the hidden webView, and must not get the selection stuck (Task 8 test `loadingFrameIsSelectableButNotActive`).
2. Window loses focus / ⌘Tab mid frame drag → the position is committed at its current value and undoable in one step, and the overlay guides disappear (Task 5 `cancelDuringMoveCommitsOnce`, Task 8 `focusLossCommitsMove`).
3. Trackpad scroll that starts on the canvas and whose momentum slides over the active frame → still pans the canvas, without suddenly scrolling the web page (Task 4 `momentumKeepsLockedTarget`).
4. Undo a move, switch web projects, then ⌘Z → must not write the old web project's positions into the new one (Task 8 `switchingProjectClearsUndo`).
5. Clicking a frame while a zoom gesture is in progress → commit the transform first, so hit testing uses the real positions (Task 10 `pointerDownCommitsPendingZoom`).

---

### Task 1: Geometry Range and Rect Helpers

**Files:**
- Modify: `native/Sources/AtlasCore/Geometry.swift`
- Test: `native/Tests/AtlasCoreTests/GeometryTests.swift`

**Interfaces:**
- Produces: `CanvasGeometry.minScale == 0.05`, `maxScale == 4`; `Rect` gains `minX/maxX/midX/minY/maxY/midY: Double`, `func intersects(_ other: Rect) -> Bool`, `func offsetBy(_ d: Point) -> Rect`, `static func union(_ rects: [Rect]) -> Rect?`, `static func spanning(_ a: Point, _ b: Point) -> Rect` (the normalized rectangle formed by two points). `Point` gains `static func +` / `-`.

- [ ] **Step 1: Modify and add tests**

In `frameDraggingAndFitUseCanvasCoordinates`, change the clamping assertions to `scale: 100` → `4` and `scale: 0` → `0.05`. Add:

```swift
@Test func rectHelpers() {
    let a = Rect(x: 0, y: 0, width: 100, height: 50)
    #expect(a.midX == 50 && a.maxY == 50)
    #expect(a.intersects(Rect(x: 99, y: 49, width: 10, height: 10)))
    #expect(!a.intersects(Rect(x: 100, y: 0, width: 10, height: 10)))   // merely touching does not count as intersecting
    #expect(Rect.union([a, Rect(x: -10, y: 20, width: 5, height: 100)]) == Rect(x: -10, y: 0, width: 110, height: 120))
    #expect(Rect.union([]) == nil)
    #expect(Rect.spanning(Point(x: 10, y: 5), Point(x: 0, y: 25)) == Rect(x: 0, y: 5, width: 10, height: 20))
    #expect(a.offsetBy(Point(x: 3, y: -2)) == Rect(x: 3, y: -2, width: 100, height: 50))
}

@Test func fitNeverZoomsBeyondActualSize() {
    let tiny = Rect(x: 0, y: 0, width: 10, height: 10)
    #expect(CanvasGeometry.fitRects([tiny], size: Size(width: 800, height: 600)).scale == 1)
}
```

- [ ] **Step 2:** Run `swift test --package-path native --disable-sandbox --filter GeometryTests`; expect FAIL (`midX` undefined, clamp values wrong).
- [ ] **Step 3:** Implement the members above in `Geometry.swift`; `intersects` uses strict inequalities.
- [ ] **Step 4:** Rerun the same command; expect PASS; then run `pnpm test:native`, all green.
- [ ] **Step 5:** Commit `feat(core): widen zoom range and add rect helpers`.

### Task 2: Snapping

**Files:**
- Create: `native/Sources/AtlasCore/Snapping.swift`
- Test: `native/Tests/AtlasCoreTests/SnappingTests.swift`

**Interfaces:**
- Consumes: the `Rect` helpers from Task 1.
- Produces:

```swift
public struct Guide: Equatable {
    public enum Axis: Equatable { case vertical, horizontal }   // vertical = a vertical line at a fixed x
    public var axis: Axis; public var position: Double; public var start: Double; public var end: Double
}
public enum Snapping {
    public static func snap(_ moving: Rect, to others: [Rect], threshold: Double) -> (offset: Point, guides: [Guide])
}
```

Algorithm: for each axis separately, compare moving's {min, mid, max} with each other's {min, mid, max}, and take the difference with the smallest `|other - moving|` that is ≤ threshold as that axis's offset (ties go to the first one found); with no candidate, that axis is 0. After applying the offset, generate one guide for every pair whose difference equals the chosen one (tolerance 0.001): for a vertical line, `position` is the aligned x and `start/end` is the union of the two rectangles' y ranges; horizontal lines are symmetric.

- [ ] **Step 1: Write tests**

```swift
@Test func snapsLeftEdgeWithinThreshold() {
    let r = Snapping.snap(Rect(x: 104, y: 300, width: 50, height: 50), to: [Rect(x: 100, y: 0, width: 200, height: 100)], threshold: 6)
    #expect(r.offset == Point(x: -4, y: 0))
    #expect(r.guides == [Guide(axis: .vertical, position: 100, start: 0, end: 350)])
}
@Test func snapsCentersAndPicksNearest() {
    // moving midX = 205, other midX = 200 (difference 5), other maxX = 300 (far)
    let r = Snapping.snap(Rect(x: 180, y: 0, width: 50, height: 10), to: [Rect(x: 100, y: 500, width: 200, height: 10)], threshold: 6)
    #expect(r.offset.x == -5)
}
@Test func noSnapOutsideThreshold() {
    let r = Snapping.snap(Rect(x: 110, y: 0, width: 10, height: 10), to: [Rect(x: 100, y: 500, width: 1, height: 1)], threshold: 6)
    #expect(r.offset == Point(x: 0, y: 0) && r.guides.isEmpty)
}
@Test func snapsBothAxes() {
    let r = Snapping.snap(Rect(x: 2, y: 103, width: 10, height: 10), to: [Rect(x: 0, y: 100, width: 50, height: 50)], threshold: 6)
    #expect(r.offset == Point(x: -2, y: -3))
    #expect(r.guides.count == 2)
}
```

- [ ] **Step 2:** `--filter SnappingTests`; expect FAIL (undefined).
- [ ] **Step 3:** Implement `Snapping.snap`.
- [ ] **Step 4:** Expect PASS.
- [ ] **Step 5:** Commit `feat(core): add frame snapping`.

### Task 3: Viewport Animation Interpolation

**Files:**
- Create: `native/Sources/AtlasCore/ViewportAnimation.swift`
- Test: `native/Tests/AtlasCoreTests/ViewportAnimationTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ViewportAnimation {
    public static let duration = 0.2
    public static func easeOut(_ t: Double) -> Double          // 1 - (1 - t)^3, t clamped to [0, 1]
    public static func value(from: Viewport, to: Viewport, size: Size, fraction: Double) -> Viewport
}
```

`value`: scale is interpolated in log space; the world point at the viewport center is interpolated linearly; `x/y` are then derived back from the center world point and scale (`x = size.width/2 - cx * s`). fraction is the already-eased value.

- [ ] **Step 1: Write tests**

```swift
@Test func animationEndpointsAreExact() {
    let a = Viewport(x: 10, y: 20, scale: 0.25), b = Viewport(x: -300, y: 40, scale: 1), s = Size(width: 800, height: 600)
    #expect(ViewportAnimation.value(from: a, to: b, size: s, fraction: 0) == a)
    #expect(ViewportAnimation.value(from: a, to: b, size: s, fraction: 1) == b)
}
@Test func scaleInterpolatesInLogSpace() {
    let v = ViewportAnimation.value(from: Viewport(scale: 0.25), to: Viewport(scale: 1), size: Size(width: 800, height: 600), fraction: 0.5)
    #expect(abs(v.scale - 0.5) < 1e-9)
}
@Test func easeOutIsMonotonicAndClamped() {
    #expect(ViewportAnimation.easeOut(-1) == 0 && ViewportAnimation.easeOut(2) == 1)
    let samples = stride(from: 0.0, through: 1.0, by: 0.1).map(ViewportAnimation.easeOut)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 })
    #expect(ViewportAnimation.easeOut(0.5) > 0.5)
}
```

The endpoint tests allow floating-point error: compare the three components with `abs(difference) < 1e-9` (the implementation may return the endpoints directly for fraction 0/1).

- [ ] **Step 2–4:** `--filter ViewportAnimationTests` first FAILs, then PASSes after implementation.
- [ ] **Step 5:** Commit `feat(core): add viewport animation interpolation`.

### Task 4: Scroll Routing

**Files:**
- Create: `native/Sources/AtlasCore/ScrollRouting.swift`
- Test: `native/Tests/AtlasCoreTests/ScrollRoutingTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ScrollTarget: Equatable { case page, canvas }
public enum ScrollPhase: Equatable { case discrete, began, changed, ended, momentum, momentumEnded }
public struct ScrollRouter {
    public private(set) var locked: ScrollTarget?
    public init()
    public mutating func route(phase: ScrollPhase, overActivePage: Bool, zoomModifier: Bool) -> ScrollTarget
}
```

Rules: `zoomModifier` → `.canvas` (lock unchanged); `discrete` → decide by `overActivePage` and clear the lock; `began` → decide and lock; `changed/ended/momentum` → `locked ?? decide`; `momentumEnded` → return `locked ?? decide`, then clear the lock.

- [ ] **Step 1: Write tests** `beganLocksTarget` (began on the canvas → still `.canvas` at changed with overActivePage=true), `momentumKeepsLockedTarget` (began on canvas → ended → momentum passing over the web page still `.canvas` → `locked == nil` after momentumEnded), `discreteWheelRoutesPerEvent` (alternating true/false yields page/canvas), `zoomModifierAlwaysCanvas` (with began locked on the web page, zoomModifier=true returns `.canvas` and `locked == .page` stays unchanged).
- [ ] **Step 2–4:** `--filter ScrollRoutingTests` FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(core): add per-gesture scroll routing`.

### Task 5: Pointer Interaction State Machine

**Files:**
- Create: `native/Sources/AtlasCore/CanvasInteraction.swift`
- Test: `native/Tests/AtlasCoreTests/CanvasInteractionTests.swift`

**Interfaces:**
- Consumes: `Rect` helpers (Task 1), `Snapping`/`Guide` (Task 2), `CanvasGeometry.screenToWorld`.
- Produces:

```swift
public enum CanvasTool: String, Equatable { case move, hand }
public enum HitTarget: Equatable { case empty, frameHeader(String), frameContent(String) }
public enum PointerButton: Equatable { case primary, middle }
public struct PointerModifiers: OptionSet { public let rawValue: Int; shift = 1, control = 2 }
public enum InteractionEffect: Equatable {
    case select(Set<String>)
    case moveFrames([String: Point])                       // live positions (frame top-left corner, world coordinates)
    case commitMove(from: [String: Point], to: [String: Point])
    case marquee(Rect?)                                    // screen coordinates; nil hides it
    case guides([Guide])                                   // world coordinates
    case pan(Viewport)
    case focus(String)                                     // double-click title: zoom to that frame
}
public struct InteractionContext {
    public var viewport: Viewport
    public var frames: [String: Rect]                      // world coordinates, including title bar height
    public var selection: Set<String>
    public var tool: CanvasTool
    public var spaceHeld: Bool
    public var activatable: Set<String>                    // frames that finished loading and can receive web input
}
public struct CanvasInteraction {
    public static let dragThreshold = 3.0
    public static let snapThreshold = 6.0
    public init()
    public var isIdle: Bool { get }
    public static func pageReceivesPointer(hit: HitTarget, button: PointerButton, context: InteractionContext) -> Bool
    public mutating func pointerDown(at: Point, hit: HitTarget, button: PointerButton, modifiers: PointerModifiers, clickCount: Int, context: InteractionContext) -> [InteractionEffect]
    public mutating func pointerDragged(to: Point, modifiers: PointerModifiers, context: InteractionContext) -> [InteractionEffect]
    public mutating func pointerUp(at: Point, context: InteractionContext) -> [InteractionEffect]
    public mutating func cancel() -> [InteractionEffect]
}
```

Rules (input in screen coordinates):

- `pageReceivesPointer`: `button == .primary`, `tool == .move`, `!spaceHeld`, `hit == .frameContent(id)`, `selection == [id]`, and `activatable.contains(id)` all hold.
- Down: middle button / hand tool / space → panning state. Double-click on a title → `[.focus(id)]`. Shift + frame → `[.select(symmetric difference)]`, without entering a drag. Frame not selected → `[.select([id])]`, enter pressed (drag set = `[id]`). Frame already in a multi-selection → no effect, enter pressed (drag set = current selection; on release without movement and with a content hit, collapse to `[id]`). Empty → `[.select([])]` without Shift, enter marquee (base = Shift ? current selection : empty).
- Drag: pressed beyond 3 points → movingFrames; while moving, world displacement = screen displacement / scale; run `Snapping.snap(threshold: snapThreshold / scale)` on the moving set's bounding rectangle against the other frames, without snapping when `control` is held, and output `[.moveFrames, .guides]`. Marquee outputs `[.marquee(screen rect), .select(base ∪ intersecting frames)]`. Pan outputs `[.pan(starting viewport + screen displacement)]`.
- Up: movingFrames → `[.commitMove(from: start, to: final position), .guides([])]` (no commit if the position did not change); marquee → `[.marquee(nil)]`; back to idle.
- `cancel()`: movingFrames same as up; marquee → `[.marquee(nil)]`; otherwise empty; back to idle.

- [ ] **Step 1: Write tests** (with two frames `a: Rect(x:0,y:0,w:390,h:888)`, `b: Rect(x:470,y:0,w:1440,h:944)`, viewport `scale 0.5, x 0, y 0`)

  - `clickingUnselectedFrameSelectsWithoutForwarding`: pressing on `frameContent("a")` → `[.select(["a"])]`; `pageReceivesPointer` is false when selection is empty, and true when it is `["a"]` and activatable contains a.
  - `loadingFrameIsSelectableButNotActive`: selection `["a"]`, activatable empty → `pageReceivesPointer == false`.
  - `smallJitterDoesNotMove`: press at (10,10), drag to (12,11) → no `moveFrames`; release → no `commitMove`.
  - `dragMovesInWorldUnitsAndCommitsOnce`: after dragging (10,10)→(110,10), `moveFrames(["a": Point(x: 200, y: 0)])` (with no snapping candidate); release yields exactly one `commitMove(from: ["a": (0,0)], to: ["a": (200,0)])`.
  - `dragSnapsAndControlDisablesIt`: drag a to an x 4 world units from b.minX → position aligns to 470 and `guides` is non-empty; the same drag with `.control` → not aligned, `guides([])`.
  - `shiftClickTogglesSelection`, `marqueeSelectsIntersectingFrames` (screen (0,0)→(300,100) selects only a; with Shift and b already selected → selects a and b), `emptyClickClearsSelection`.
  - `multiSelectionMovesTogether`, `clickInsideMultiSelectionCollapsesOnRelease`.
  - `handToolSpaceAndMiddleButtonPan`: dragging (0,0)→(30,40) in all three ways yields `pan(Viewport(x: 30, y: 40, scale: 0.5))`.
  - `doubleClickHeaderFocuses`.
  - `cancelDuringMoveCommitsOnce`: `cancel()` during a drag → exactly one `commitMove`; `cancel()` again → empty.

- [ ] **Step 2:** `--filter CanvasInteractionTests`; expect FAIL.
- [ ] **Step 3:** Implement `CanvasInteraction` (private `State` enum: idle / pressed / movingFrames / marquee / panning).
- [ ] **Step 4:** Expect PASS; `pnpm test:native` all green.
- [ ] **Step 5:** Commit `feat(core): add canvas pointer interaction state machine`.

### Task 6: Split NativeCanvas (Pure Refactor)

**Files:**
- Modify: `native/Sources/AtlasApp/NativeCanvas.swift` (keep only the `NativeCanvas` bridge)
- Create: `native/Sources/AtlasApp/CanvasView.swift` (`AtlasCanvasView`, `CanvasWorldView`)
- Create: `native/Sources/AtlasApp/PreviewFrameView.swift`

**Interfaces:**
- Produces: class names unchanged (`AtlasCanvasView`, `PreviewFrameView`), `fileprivate` members changed to `internal`, behavior unchanged.

- [ ] **Step 1:** Move code class by class, widening access levels only as far as needed to compile.
- [ ] **Step 2:** `pnpm test:native` all green; `git diff --stat` touches only these three files.
- [ ] **Step 3:** Commit `refactor(native): split canvas into focused files`.

### Task 7: Store and Bridge Data Flow

**Files:**
- Create: `native/Sources/AtlasApp/CanvasModel.swift`
- Modify: `native/Sources/AtlasApp/AtlasStore.swift`, `NativeCanvas.swift`, `CanvasView.swift`, `PreviewFrameView.swift`, `WorkspaceView.swift`, `AtlasApp.swift`
- Test: `native/Tests/AtlasAppTests/StoreTests.swift` (new), `ViewportTests.swift`

**Interfaces:**
- Consumes: `CanvasTool` (Task 5), `ViewportAnimation` (Task 3, type only).
- Produces (`CanvasModel.swift`):

```swift
struct ViewportRequest: Equatable { var viewport: Viewport; var animated: Bool; var token: Int }
@MainActor final class ZoomIndicator: ObservableObject {
    @Published private(set) var scale = 1.0
    private(set) var viewport = Viewport()          // live viewport, not published
    func update(_ viewport: Viewport)               // stores viewport; publishes only when scale changes by ≥0.5%
}
```

`AtlasStore` changes:
- Delete `@Published interactingFrameID`; add `@Published var selection: Set<String> = []`, `@Published var tool: CanvasTool = .move`, `@Published private(set) var viewportRequest = ViewportRequest(viewport: Viewport(), animated: false, token: 0)`, `@Published private(set) var positionsToken = 0`, `let zoomIndicator = ZoomIndicator()`.
- `viewport` stays as the settled viewport (no longer `@Published`).
- `func viewportSettled(_ v: Viewport)`: writes `viewport`, calls `zoomIndicator.update`, `scheduleSave()`.
- `func framesMoved(_ moved: [String: Point])`: merges into `positions`, `scheduleSave()`; does not change `positionsToken`.
- `func request(_ v: Viewport, animated: Bool)` (private): token+1, writes both `viewport` and `zoomIndicator`.
- `fitAll(animated: Bool = true)`, `focusFrame(_:)`, `zoomToSelection()` (same as `fitAll` when the selection is empty), and `zoom(_:)` (based on `zoomIndicator.viewport`, anchored at the canvas center) all go through `request`. `select(project)` and `reset()` use `animated: false`, and do `positionsToken += 1`, `selection = []`.
- Delete `updateViewport` and `moveFrame`.

`NativeCanvas` parameters become: `project, positions, positionsToken, viewportRequest, selection, tool, reloadToken, zoomIndicator`, with callbacks `onViewportSettled(Viewport)`, `onFramesMoved([String: Point])`, `onSelectionChange(Set<String>)`, `onToolChange(CanvasTool)`, `onFocusFrame(String)`, `onSizeChange(CGSize)`. `AtlasCanvasView.update` acts only when the project, `positionsToken`, `viewportRequest.token`, or `reloadToken` changes (in this task every request is applied immediately; animation comes in Task 10). In this task the canvas keeps its old input code, only replacing the "interacting" check with `selection.count == 1 && selection.contains(id)`.

UI: delete the Interacting (正在交互) banner at the top of `WorkspaceView`, `PreviewFrameView`'s `interactionButton`, and the `AtlasApp` menu item Exit Web Interaction (退出网页交互). The toolbar zoom percentage reads `@ObservedObject zoomIndicator` instead (extracted into a `ZoomLabel` subview).

- [ ] **Step 1: Write tests** (`StoreTests.swift`, reusing the Project construction from `ViewportTests`, extracted into a private test function `sampleProject(id:)`)
  - `fitAllIssuesAnimatedRequestWithNewToken`: record the token after `select`, then `fitAll()` → token +1 and `animated == true`.
  - `selectingProjectResetsSelectionAndBumpsPositionsToken`.
  - `settledViewportIsSavedAndReflected`: after `viewportSettled(v)`, `store.viewport == v` and `zoomIndicator.scale == v.scale`.
  - `framesMovedMergesPositions`.
  - `zoomToSelectionFallsBackToFitAll`.
  - Keep and update `resizingAfterSwitchingToANewProjectPreservesTheUsersViewport` (API unchanged; it should keep passing).
- [ ] **Step 2:** `--filter StoreTests`; expect FAIL.
- [ ] **Step 3:** Implement the Store, bridge, and UI changes above.
- [ ] **Step 4:** `pnpm test:native` all green; after launching with `pnpm dev`, confirm manually: toolbar zoom, ⌘0, and the bottom focus buttons work; there is no Enter Interaction (进入交互) button.
- [ ] **Step 5:** Commit `refactor(native): settle-based canvas data flow`.

### Task 8: Canvas Pointer Input, Overlay, and Undo

**Files:**
- Create: `native/Sources/AtlasApp/CanvasOverlay.swift`
- Modify: `native/Sources/AtlasApp/CanvasView.swift`, `PreviewFrameView.swift`
- Test: `native/Tests/AtlasAppTests/CanvasInputTests.swift` (new)

**Interfaces:**
- Consumes: `CanvasInteraction`, `InteractionEffect`, `HitTarget`, `InteractionContext` (Task 5); Task 7 callbacks.
- Produces:
  - `CanvasOverlay: NSView` (`hitTest` always returns nil), with method `func render(viewport: Viewport, frames: [String: Rect], selection: Set<String>, active: String?, hover: String?, marquee: Rect?, guides: [Guide])`. Uses CAShapeLayer: selection 2pt `controlAccentColor`, hover 1pt in the same color, an extra outer outline for the active frame, marquee with a translucent accent fill + 1pt stroke, guides 1pt `systemRed`; colors update when the appearance changes.
  - `PreviewFrameView.isReady: Bool` (true after `didFinish`, false on failure/reload); remove the drawing for `selected` and `interactive`, keeping only the title and the border separator; `retryButton` and `externalButton` stay clickable.
  - `AtlasCanvasView` gains `func hitTarget(at screen: NSPoint) -> HitTarget` (searches frames from top to bottom in z-order; the title area = the top `CanvasGeometry.headerHeight` world units).

Implementation notes:
- `AtlasCanvasView.hitTest`: on a frame's `retryButton/externalButton`, return the button; if `CanvasInteraction.pageReceivesPointer` is true, return `super.hitTest` (the webView subtree); otherwise return `self`. `CanvasWorldView` and `PreviewFrameView` no longer handle mouse events.
- `mouseDown/Dragged/Up`, `otherMouseDown/Dragged/Up` (middle button), and `mouseMoved` (`NSTrackingArea` updates hover) forward events to `CanvasInteraction`, all executed by `apply(_ effects: [InteractionEffect])`: `select` → update the selection, the overlay, and `onSelectionChange`; `moveFrames` → change frame origins (no callback); `commitMove` → `onFramesMoved(to)` + register undo; `pan` → update the viewport (keep using the existing `applyViewport` until Task 10); `focus` → `onFocusFrame`.
- Undo: `registerMove(from:to:)` uses `window?.undoManager`, with the action name Move Frame (移动画框); undo applies `from` and registers the reverse. On project switch and `positionsToken` changes, call `undoManager?.removeAllActions(withTarget: self)`.
- `releaseHeldInput()` additionally calls `interaction.cancel()` and `apply`.
- The Esc web bridge (`atlasExit`) changes to: clear the selection and `window?.makeFirstResponder(canvas)`.
- Append the Selected (，已选中) / Active (，活动) suffix to frame accessibility labels.

- [ ] **Step 1: Write tests** (build an `NSWindow` + `AtlasCanvasView`, pass a two-frame project to `update`; synthesize events with `NSEvent.mouseEvent(with:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:)` and call `mouseDown` etc. directly)
  - `clickSelectsAndReportsSelection`: click frame a's content → `onSelectionChange` receives `["a"]`; `hitTest` at a's content returns `canvas` (not finished loading).
  - `dragCommitsAndUndoRestores`: drag a by 100 points → `onFramesMoved` receives the new position; `window.undoManager?.undo()` → called back again with the original position; `redo()` returns to the new position.
  - `focusLossCommitsMove`: post `NSWindow.didResignKeyNotification` during a drag → exactly one `onFramesMoved`.
  - `switchingProjectClearsUndo`: after a drag, `update` with another project → `undoManager.canUndo == false`.
- [ ] **Step 2:** `--filter CanvasInputTests`; expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `pnpm test:native` all green; with `pnpm dev`, confirm manually: the first click only selects, a second click operates the web page, marquee selection, Shift multi-select, moving together, red guides, ⌘Z/⇧⌘Z.
- [ ] **Step 5:** Commit `feat(native): figma-style selection, marquee, snapping and undo`.

### Task 9: Scroll Routing, Tools, and Shortcuts

**Files:**
- Modify: `native/Sources/AtlasApp/CanvasView.swift`, `WorkspaceView.swift`
- Test: `native/Tests/AtlasAppTests/CanvasInputTests.swift`

**Interfaces:**
- Consumes: `ScrollRouter` (Task 4), `CanvasTool`, Task 7's `onToolChange` and `onFocusFrame`; the Store's `fitAll()`, `zoomToSelection()`, and `zoom(_:)` are called through a new callback `onCommand(CanvasCommand)`.
- Produces: `enum CanvasCommand: Equatable { case fitAll, zoomToSelection, actualSize }` (defined in `CanvasModel.swift`); `NativeCanvas` gains an `onCommand` parameter, which `WorkspaceView` maps to the store.

Implementation notes:
- `.scrollWheel` in the local event monitor: map `phase/momentumPhase` to `ScrollPhase` (both empty → `.discrete`); `overActivePage` = the pointer hits the active frame's content; `zoomModifier` = ⌘ or ⌃. Target `.page`: if the pointer is over that webView, return the event unchanged; otherwise call the active webView's `scrollWheel(with:)` and swallow the event. Target `.canvas`: call the canvas scroll/zoom and swallow the event.
- `keyDown` (when the canvas is first responder): keyCode 18/19/29 + Shift → `onCommand(.fitAll/.zoomToSelection/.actualSize)`; `v`/`h` → `onToolChange`; arrow keys move the selection (10/100), each key press being one undo step and calling `onFramesMoved`; Return with a sole, ready selection → `makeFirstResponder(webView)`; Esc → clear the selection; ⌘A → select all.
- With the hand tool the cursor is `openHand`, and `closedHand` while dragging.
- The toolbar gains a segmented `Picker` (Move V (移动 V) with `cursorarrow` / Hand H (抓手 H) with `hand.raised`) bound to `store.tool`. The bottom hint changes to the spec text: `点选画框后可直接操作 · 空格拖动平移 · ⌘滚轮或捏合缩放 · Shift+1 适应全部`.

- [ ] **Step 1: Write tests**
  - `arrowKeysNudgeSelectionAndUndoAsOneStep`: select a, synthesize a right-arrow keyDown → position x +10, with Shift → +100; one `undo()` undoes only the most recent one.
  - `shiftDigitsIssueCommands`: synthesize Shift+1/2/0 → `onCommand` receives the three commands in order.
  - `toolKeysReportToolChange`: `v`, `h`.
- [ ] **Step 2–4:** FAIL → implement → `pnpm test:native` all green; with `pnpm dev`, confirm manually that trackpad momentum sliding over the active frame does not switch targets, and that scrolling inside the active frame scrolls the web page.
- [ ] **Step 5:** Commit `feat(native): scroll routing, tools and figma shortcuts`.

### Task 10: Rendering Performance and Animation

**Files:**
- Create: `native/Sources/AtlasApp/CanvasGrid.swift`
- Modify: `native/Sources/AtlasApp/CanvasView.swift`
- Test: `native/Tests/AtlasAppTests/CanvasInputTests.swift`

**Interfaces:**
- Consumes: `ViewportAnimation` (Task 3), `ViewportRequest`, `ZoomIndicator` (Task 7).
- Produces: `CanvasGrid: CALayer`, `func update(viewport: Viewport, bounds: CGRect)`. Implemented as two levels of `CAReplicatorLayer` (replicating a 1.5pt dot along x, and that row along y), with replication spacing = `32 * scale`; panning only changes the phase of the root layer's `position` (`viewport.x/y` modulo the spacing), without rebuilding sublayers; `isHidden = true` when the spacing is < 8; the color is `separatorColor` at 55% opacity, updated when the appearance changes. `AtlasCanvasView` internally keeps `committedViewport` and `liveViewport`.

Implementation notes:
- View hierarchy: `AtlasCanvasView` → `gridLayer` (layer) → `zoomHost: NSView` (`wantsLayer`, hosting `world`) → `CanvasOverlay`. Delete the per-dot `NSBezierPath` in `draw(_:)`.
- Pan: change `world.bounds.origin` directly and sync `committedViewport` (cheap).
- Zoom (pinch, ⌘ scroll wheel, animation, animated requests): only set `zoomHost.layer?.sublayerTransform` (the scale and translation from committed → live), updated inside `CATransaction.setDisableActions(true)`; on settling (pinch `phase == .ended`, ⌘ scroll wheel idle for 150ms, animation finished) commit it to `world.bounds` and reset the transform, then `onViewportSettled(live)`.
- Any `mouseDown`/`otherMouseDown`/`keyDown` first calls `commitPendingZoom()`; new input during an animation → stop the animation and continue from the current `liveViewport`.
- Drive the animation with `displayLink(target:selector:)` (the macOS 14 NSView API), with duration `ViewportAnimation.duration`.
- Throttle `zoomIndicator.update(liveViewport)` to ≤30Hz.
- Debugging: when the environment variable `UI_ATLAS_FRAME_LOG=1` is set, use the same display link to count frame intervals >25ms, printing `[frame] hitches=N frames=M` to stderr once per second.
- To verify by measurement: if committing on zoom settle visibly flickers in a real example, switch to committing about every 100ms during the gesture, and record the conclusion in `docs/native-verification.md`.

- [ ] **Step 0: Add the frame log first and measure a baseline**: implement only the `UI_ATLAS_FRAME_LOG` counting (display link); on the code before the rendering changes, run `UI_ATLAS_FRAME_LOG=1 pnpm dev` with 10 seconds of continuous panning + 10 seconds of pinching, and record the hitches count as the baseline.
- [ ] **Step 1: Write tests**
  - `pointerDownCommitsPendingZoom`: after calling `magnify` (phase `.changed`), `world.bounds` is unchanged; a following `mouseDown` → `world.bounds` reflects the new zoom and `onViewportSettled` is called once.
  - `animatedRequestSettlesAtTarget`: issue an `animated: true` request, call the test hook `advanceAnimation(to: 1)` directly → `onViewportSettled` receives the target viewport.
  - `gridHidesWhenDense`: `gridLayer.isHidden == true` at `scale = 0.2`, false at `scale = 1`.
- [ ] **Step 2–4:** FAIL → implement → `pnpm test:native` all green.
- [ ] **Step 5:** Measure the hitches count again with the same operations and compare against the Step 0 baseline; the results are written into the verification record in Task 11.
- [ ] **Step 6:** Commit `perf(native): layer-backed grid, transform zoom and animated viewport`.

### Task 11: Docs and Real-App Acceptance

**Files:**
- Modify: `docs/macos.md` (rewrite the whole "Canvas operations" section per spec section 1), `GLOSSARY.md` (replace "interaction mode" with "**Active frame**: the sole selected, loaded frame; pointer and keyboard input go directly to its web page."), `docs/native-verification.md` (add a "Figma-style interaction acceptance" subsection), `README.md` (correct the native-related descriptions in "How to use" if they conflict)

- [ ] **Step 1:** Update the docs.
- [ ] **Step 2:** Run the full gate: `pnpm test:native`, `pnpm check`, `pnpm build:native`, `codesign --verify --deep --strict dist/界面图鉴.app`, all passing.
- [ ] **Step 3:** Use `open dist/界面图鉴.app` to go through the "Real-App acceptance" checklist in spec section 4 item by item, saving screenshots of light, dark, and a narrow window of about 940×672 into `docs/evidence/` (`native-figma-light.png`, `native-figma-dark.png`), and write the frame-interval comparison into the verification record.
- [ ] **Step 4:** Local review (Heavy tier: two independent reviews, Standards and Spec); fix valid findings.
- [ ] **Step 5:** Commit `docs: document figma-style canvas interaction and acceptance`; update `Status:` in `.scratch/figma-canvas/spec.md` to "Implemented".
