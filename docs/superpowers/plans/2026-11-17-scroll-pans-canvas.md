# Scrolling Always Pans the Canvas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scrolling pans the canvas by default; ⌥ + scroll over the active frame scrolls the web page.

**Architecture:** The rules live in `AtlasCore.ScrollRouter` (testable); `AtlasCanvasView.routeScrollEvent` only reads the modifier keys and executes.

**Tech Stack:** Swift 6 / Swift Testing / AppKit

**Spec:** `docs/superpowers/specs/2026-11-17-scroll-pans-canvas-design.md`

## Global Constraints

- UI text and documentation are in Chinese; `docs/macos.md` is the authoritative interaction spec.
- Zoom modifiers (⌘ / ⌃) take priority over ⌥.

## Review Focus

- ⌥ pressed midway through a trackpad gesture: the target does not change (still the canvas) — test `optionPressedMidGestureKeepsCanvas`.
- Gesture starts with ⌥ and it is released midway: keeps scrolling the web page until momentum ends — test `optionReleasedMidGestureKeepsPage`.
- ⌥ over an inactive frame or empty space: pans the canvas — test `optionOutsideActivePageIsCanvas`.
- ⌘ + ⌥ pressed together: zoom — test `zoomModifierAlwaysCanvas`.

---

### Task 1: ScrollRouter rules and CanvasView wiring

**Files:**
- Modify: `native/Sources/AtlasCore/ScrollRouting.swift`
- Modify: `native/Sources/AtlasApp/CanvasView.swift` (`routeScroll`, `routeScrollEvent`)
- Test: `native/Tests/AtlasCoreTests/ScrollRoutingTests.swift`
- Docs: the scrolling entry under "Navigation" in `docs/macos.md`

**Interfaces:**
- Produces: `ScrollRouter.route(phase: ScrollPhase, overActivePage: Bool, pageModifier: Bool, zoomModifier: Bool) -> ScrollTarget`

- [ ] Rewrite tests: add the `pageModifier` argument to existing cases; add `plainScrollOverActivePageIsCanvas`, `optionPressedMidGestureKeepsCanvas`, `optionReleasedMidGestureKeepsPage`, `optionOutsideActivePageIsCanvas`, and per-event decision for discrete mouse wheels.
- [ ] `swift test --filter ScrollRouting` fails (compile error).
- [ ] Implement: `fresh = overActivePage && pageModifier ? .page : .canvas`.
- [ ] CanvasView passes `event.modifierFlags.contains(.option)`.
- [ ] Update `docs/macos.md`; `pnpm test:native` passes.
- [ ] Check the real app in light and dark, saving screenshots to `docs/evidence/native-scroll-pans-canvas-{light,dark}.jpg`.
- [ ] Commit.
