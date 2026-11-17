# 滚动始终平移画布 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 滚动默认平移画布，⌥ + 滚动在活动画框上滚动网页。

**Architecture:** 规则放在 `AtlasCore.ScrollRouter`（可测试），`AtlasCanvasView.routeScrollEvent` 只负责读取修饰键并执行。

**Tech Stack:** Swift 6 / Swift Testing / AppKit

**Spec:** `docs/superpowers/specs/2026-11-17-scroll-pans-canvas-design.md`

## Global Constraints

- 界面文案与文档用中文；`docs/macos.md` 为交互权威规范。
- 缩放修饰键（⌘ / ⌃）优先于 ⌥。

## Review Focus

- 触控板手势中途按下 ⌥：目标不变（仍是画布）——测试 `optionPressedMidGestureKeepsCanvas`。
- 手势以 ⌥ 开始、中途松开：继续滚动网页直到惯性结束——测试 `optionReleasedMidGestureKeepsPage`。
- ⌥ 在非活动画框或空白处：平移画布——测试 `optionOutsideActivePageIsCanvas`。
- ⌘ + ⌥ 同时按下：缩放——测试 `zoomModifierAlwaysCanvas`。

---

### Task 1: ScrollRouter 规则与 CanvasView 接入

**Files:**
- Modify: `native/Sources/AtlasCore/ScrollRouting.swift`
- Modify: `native/Sources/AtlasApp/CanvasView.swift`（`routeScroll`、`routeScrollEvent`）
- Test: `native/Tests/AtlasCoreTests/ScrollRoutingTests.swift`
- Docs: `docs/macos.md`“导航”滚动条目

**Interfaces:**
- Produces: `ScrollRouter.route(phase: ScrollPhase, overActivePage: Bool, pageModifier: Bool, zoomModifier: Bool) -> ScrollTarget`

- [ ] 改写测试：现有用例补 `pageModifier` 参数；新增 `plainScrollOverActivePageIsCanvas`、`optionPressedMidGestureKeepsCanvas`、`optionReleasedMidGestureKeepsPage`、`optionOutsideActivePageIsCanvas`、离散滚轮逐事件判断。
- [ ] `swift test --filter ScrollRouting` 失败（编译错误）。
- [ ] 实现：`fresh = overActivePage && pageModifier ? .page : .canvas`。
- [ ] CanvasView 传入 `event.modifierFlags.contains(.option)`。
- [ ] 更新 `docs/macos.md`；`pnpm test:native` 通过。
- [ ] 真实应用浅色、深色检查，截图存 `docs/evidence/native-scroll-pans-canvas-{light,dark}.jpg`。
- [ ] 提交。
