# Figma 式画布交互 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把原生 macOS 画布改成 Figma 式“先选中再操作”的交互，并消除平移/缩放卡顿。

**Architecture:** 输入、吸附、滚动路由、视角动画抽成 `AtlasCore` 纯逻辑并先写测试；AppKit `CanvasView` 持有实时视角、位置与选择，只在“停下”时同步给 SwiftUI `AtlasStore`；网格与覆盖层改用 CALayer，缩放手势中用 layer 变换、停下后再提交 bounds。

**Tech Stack:** Swift 6 工具链（语言模式 v5）、SwiftUI + AppKit + WebKit、Swift Testing，macOS 14+，无第三方依赖。

**Spec:** `.scratch/figma-canvas/spec.md`

## Global Constraints

- 只改 `native/` 与文档；`apps/atlas`、`examples/`、`catalog.json` 格式不动。
- macOS 14 部署目标，`swiftLanguageModes: [.v5]`，不加 Swift 包依赖。
- 界面文案为简体中文；新增文案以 spec 原文为准。
- 缩放范围 `minScale = 0.05`、`maxScale = 4`；“适应全部 / 缩放至选择 / 聚焦”结果上限 100%。
- 拖动阈值 3 屏幕点；吸附阈值 6 屏幕点（世界单位 `6 / scale`）；动画 200ms ease-out；停下判定空闲 150ms；缩放指示 ≤30Hz。
- 方向键移动 10，Shift+方向键 100；方向键不吸附。
- 每个任务结束 `pnpm test:native` 全绿；提交信息结尾带 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`；只 `git add` 本任务文件。
- 单测快速运行：`swift test --package-path native --disable-sandbox --filter <TestName>`。

## Review Focus

1. 已选中画框正在加载或失败（webView 隐藏）时点击内容 → 不应把事件交给隐藏的 webView，也不应卡住选择（Task 8 测试 `loadingFrameIsSelectableButNotActive`）。
2. 拖动画框中途窗口失焦 / ⌘Tab → 位置按当前值提交且可撤销一步，覆盖层参考线消失（Task 5 `cancelDuringMoveCommitsOnce`，Task 8 `focusLossCommitsMove`）。
3. 触控板滚动从画布开始、惯性滑过活动画框 → 仍平移画布，不突然滚动网页（Task 4 `momentumKeepsLockedTarget`）。
4. 撤销移动后切换作品再 ⌘Z → 不应把旧作品的位置写进新作品（Task 8 `switchingProjectClearsUndo`）。
5. 缩放手势进行中点击画框 → 先提交变换，命中测试基于真实位置（Task 10 `pointerDownCommitsPendingZoom`）。

---

### Task 1: 几何范围与矩形辅助

**Files:**
- Modify: `native/Sources/AtlasCore/Geometry.swift`
- Test: `native/Tests/AtlasCoreTests/GeometryTests.swift`

**Interfaces:**
- Produces: `CanvasGeometry.minScale == 0.05`、`maxScale == 4`；`Rect` 新增 `minX/maxX/midX/minY/maxY/midY: Double`、`func intersects(_ other: Rect) -> Bool`、`func offsetBy(_ d: Point) -> Rect`、`static func union(_ rects: [Rect]) -> Rect?`、`static func spanning(_ a: Point, _ b: Point) -> Rect`（两点构成的规范化矩形）。`Point` 新增 `static func +` / `-`。

- [ ] **Step 1: 修改并新增测试**

把 `frameDraggingAndFitUseCanvasCoordinates` 中的钳制断言改为 `scale: 100` → `4`、`scale: 0` → `0.05`。新增：

```swift
@Test func rectHelpers() {
    let a = Rect(x: 0, y: 0, width: 100, height: 50)
    #expect(a.midX == 50 && a.maxY == 50)
    #expect(a.intersects(Rect(x: 99, y: 49, width: 10, height: 10)))
    #expect(!a.intersects(Rect(x: 100, y: 0, width: 10, height: 10)))   // 仅接触不算相交
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

- [ ] **Step 2:** 运行 `swift test --package-path native --disable-sandbox --filter GeometryTests`，预期 FAIL（`midX` 未定义、钳制值不符）。
- [ ] **Step 3:** 在 `Geometry.swift` 实现上述成员；`intersects` 用严格不等式。
- [ ] **Step 4:** 重跑同一命令，预期 PASS；再跑 `pnpm test:native` 全绿。
- [ ] **Step 5:** 提交 `feat(core): widen zoom range and add rect helpers`。

### Task 2: 吸附

**Files:**
- Create: `native/Sources/AtlasCore/Snapping.swift`
- Test: `native/Tests/AtlasCoreTests/SnappingTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `Rect` 辅助。
- Produces:

```swift
public struct Guide: Equatable {
    public enum Axis: Equatable { case vertical, horizontal }   // vertical = 固定 x 的竖线
    public var axis: Axis; public var position: Double; public var start: Double; public var end: Double
}
public enum Snapping {
    public static func snap(_ moving: Rect, to others: [Rect], threshold: Double) -> (offset: Point, guides: [Guide])
}
```

算法：每轴分别比较 moving 的 {min, mid, max} 与每个 other 的 {min, mid, max}，取 `|other - moving|` 最小且 ≤ threshold 的差值作为该轴偏移（并列取先出现者）；无候选则该轴为 0。偏移应用后，对每个与选中差值相等（误差 0.001）的配对生成一条参考线：竖线 `position` 为对齐的 x，`start/end` 为两矩形 y 范围的并集；横线对称。

- [ ] **Step 1: 写测试**

```swift
@Test func snapsLeftEdgeWithinThreshold() {
    let r = Snapping.snap(Rect(x: 104, y: 300, width: 50, height: 50), to: [Rect(x: 100, y: 0, width: 200, height: 100)], threshold: 6)
    #expect(r.offset == Point(x: -4, y: 0))
    #expect(r.guides == [Guide(axis: .vertical, position: 100, start: 0, end: 350)])
}
@Test func snapsCentersAndPicksNearest() {
    // moving midX = 205，other midX = 200（差 5），other maxX = 300（远）
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

- [ ] **Step 2:** `--filter SnappingTests` 预期 FAIL（未定义）。
- [ ] **Step 3:** 实现 `Snapping.snap`。
- [ ] **Step 4:** 预期 PASS。
- [ ] **Step 5:** 提交 `feat(core): add frame snapping`。

### Task 3: 视角动画插值

**Files:**
- Create: `native/Sources/AtlasCore/ViewportAnimation.swift`
- Test: `native/Tests/AtlasCoreTests/ViewportAnimationTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ViewportAnimation {
    public static let duration = 0.2
    public static func easeOut(_ t: Double) -> Double          // 1 - (1 - t)^3，t 钳制到 [0, 1]
    public static func value(from: Viewport, to: Viewport, size: Size, fraction: Double) -> Viewport
}
```

`value`：scale 在对数空间插值；视口中心对应的世界点线性插值；再由中心世界点和 scale 反推 `x/y`（`x = size.width/2 - cx * s`）。fraction 为已缓动的值。

- [ ] **Step 1: 写测试**

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

端点测试允许浮点误差：用 `abs(差) < 1e-9` 比较三个分量（实现中 fraction 0/1 可直接返回端点）。

- [ ] **Step 2–4:** `--filter ViewportAnimationTests` 先 FAIL，实现后 PASS。
- [ ] **Step 5:** 提交 `feat(core): add viewport animation interpolation`。

### Task 4: 滚动路由

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

规则：`zoomModifier` → `.canvas`（不改锁）；`discrete` → 按 `overActivePage` 判定并清锁；`began` → 判定并锁定；`changed/ended/momentum` → `locked ?? 判定`；`momentumEnded` → 返回 `locked ?? 判定` 后清锁。

- [ ] **Step 1: 写测试** `beganLocksTarget`（began 在画布 → changed 时 overActivePage=true 仍 `.canvas`）、`momentumKeepsLockedTarget`（began 画布 → ended → momentum 经过网页仍 `.canvas` → momentumEnded 后 `locked == nil`）、`discreteWheelRoutesPerEvent`（交替 true/false 得到 page/canvas）、`zoomModifierAlwaysCanvas`（began 锁在网页时 zoomModifier=true 返回 `.canvas`，且 `locked == .page` 不变）。
- [ ] **Step 2–4:** `--filter ScrollRoutingTests` FAIL → 实现 → PASS。
- [ ] **Step 5:** 提交 `feat(core): add per-gesture scroll routing`。

### Task 5: 指针交互状态机

**Files:**
- Create: `native/Sources/AtlasCore/CanvasInteraction.swift`
- Test: `native/Tests/AtlasCoreTests/CanvasInteractionTests.swift`

**Interfaces:**
- Consumes: `Rect` 辅助（Task 1）、`Snapping`/`Guide`（Task 2）、`CanvasGeometry.screenToWorld`。
- Produces:

```swift
public enum CanvasTool: String, Equatable { case move, hand }
public enum HitTarget: Equatable { case empty, frameHeader(String), frameContent(String) }
public enum PointerButton: Equatable { case primary, middle }
public struct PointerModifiers: OptionSet { public let rawValue: Int; shift = 1, control = 2 }
public enum InteractionEffect: Equatable {
    case select(Set<String>)
    case moveFrames([String: Point])                       // 实时位置（画框左上角，世界坐标）
    case commitMove(from: [String: Point], to: [String: Point])
    case marquee(Rect?)                                    // 屏幕坐标；nil 隐藏
    case guides([Guide])                                   // 世界坐标
    case pan(Viewport)
    case focus(String)                                     // 双击标题：缩放至该画框
}
public struct InteractionContext {
    public var viewport: Viewport
    public var frames: [String: Rect]                      // 世界坐标，含标题栏高度
    public var selection: Set<String>
    public var tool: CanvasTool
    public var spaceHeld: Bool
    public var activatable: Set<String>                    // 已加载完成、可接收网页输入的画框
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

规则（屏幕坐标输入）：

- `pageReceivesPointer`：`button == .primary`、`tool == .move`、`!spaceHeld`、`hit == .frameContent(id)`、`selection == [id]`、`activatable.contains(id)` 全部成立。
- 按下：中键 / 抓手工具 / 空格 → 平移状态。标题双击 → `[.focus(id)]`。Shift + 画框 → `[.select(对称差)]`，不进入拖动。画框且未选中 → `[.select([id])]`，进入 pressed（拖动集合 = `[id]`）。画框且已在多选中 → 无效果，进入 pressed（拖动集合 = 当前选择，抬起未移动且命中内容时收缩为 `[id]`）。空白 → 无 Shift 时 `[.select([])]`，进入框选（基准 = Shift ? 当前选择 : 空）。
- 拖动：pressed 超过 3 点 → movingFrames；移动时世界位移 = 屏幕位移 / scale，对移动集合外接矩形与其它画框做 `Snapping.snap(threshold: snapThreshold / scale)`，`control` 时不吸附，输出 `[.moveFrames, .guides]`。框选输出 `[.marquee(屏幕矩形), .select(基准 ∪ 相交画框)]`。平移输出 `[.pan(起始视角 + 屏幕位移)]`。
- 抬起：movingFrames → `[.commitMove(from: 起点, to: 末位置), .guides([])]`（位置未变则不提交）；框选 → `[.marquee(nil)]`；回到 idle。
- `cancel()`：movingFrames 同抬起；框选 → `[.marquee(nil)]`；其余空；回到 idle。

- [ ] **Step 1: 写测试**（用两画框 `a: Rect(x:0,y:0,w:390,h:888)`、`b: Rect(x:470,y:0,w:1440,h:944)`，viewport `scale 0.5, x 0, y 0`）

  - `clickingUnselectedFrameSelectsWithoutForwarding`：按下 `frameContent("a")` → `[.select(["a"])]`；`pageReceivesPointer` 在 selection 为空时 false，为 `["a"]` 且 activatable 含 a 时 true。
  - `loadingFrameIsSelectableButNotActive`：selection `["a"]`、activatable 空 → `pageReceivesPointer == false`。
  - `smallJitterDoesNotMove`：按下 (10,10)，拖到 (12,11) → 无 `moveFrames`；抬起 → 无 `commitMove`。
  - `dragMovesInWorldUnitsAndCommitsOnce`：拖 (10,10)→(110,10) 后 `moveFrames(["a": Point(x: 200, y: 0)])`（无吸附候选时）；抬起恰好一个 `commitMove(from: ["a": (0,0)], to: ["a": (200,0)])`。
  - `dragSnapsAndControlDisablesIt`：把 a 拖到 x 距 b.minX 差 4 世界单位处 → 位置对齐 470 且 `guides` 非空；同拖动带 `.control` → 不对齐、`guides([])`。
  - `shiftClickTogglesSelection`、`marqueeSelectsIntersectingFrames`（屏幕 (0,0)→(300,100) 只选中 a；带 Shift 且原选 b → 选中 a、b）、`emptyClickClearsSelection`。
  - `multiSelectionMovesTogether`、`clickInsideMultiSelectionCollapsesOnRelease`。
  - `handToolSpaceAndMiddleButtonPan`：三种方式拖 (0,0)→(30,40) 均得 `pan(Viewport(x: 30, y: 40, scale: 0.5))`。
  - `doubleClickHeaderFocuses`。
  - `cancelDuringMoveCommitsOnce`：拖动中 `cancel()` → 恰一个 `commitMove`，再 `cancel()` → 空。

- [ ] **Step 2:** `--filter CanvasInteractionTests` 预期 FAIL。
- [ ] **Step 3:** 实现 `CanvasInteraction`（私有 `State` 枚举：idle / pressed / movingFrames / marquee / panning）。
- [ ] **Step 4:** 预期 PASS；`pnpm test:native` 全绿。
- [ ] **Step 5:** 提交 `feat(core): add canvas pointer interaction state machine`。

### Task 6: 拆分 NativeCanvas（纯重构）

**Files:**
- Modify: `native/Sources/AtlasApp/NativeCanvas.swift`（只留 `NativeCanvas` 桥）
- Create: `native/Sources/AtlasApp/CanvasView.swift`（`AtlasCanvasView`、`CanvasWorldView`）
- Create: `native/Sources/AtlasApp/PreviewFrameView.swift`

**Interfaces:**
- Produces: 类名不变（`AtlasCanvasView`、`PreviewFrameView`），把 `fileprivate` 成员改为 `internal`，行为不变。

- [ ] **Step 1:** 按类移动代码，访问级别仅放宽到编译通过所需。
- [ ] **Step 2:** `pnpm test:native` 全绿；`git diff --stat` 只涉及这三个文件。
- [ ] **Step 3:** 提交 `refactor(native): split canvas into focused files`。

### Task 7: Store 与桥的数据流

**Files:**
- Create: `native/Sources/AtlasApp/CanvasModel.swift`
- Modify: `native/Sources/AtlasApp/AtlasStore.swift`、`NativeCanvas.swift`、`CanvasView.swift`、`PreviewFrameView.swift`、`WorkspaceView.swift`、`AtlasApp.swift`
- Test: `native/Tests/AtlasAppTests/StoreTests.swift`（新建）、`ViewportTests.swift`

**Interfaces:**
- Consumes: `CanvasTool`（Task 5）、`ViewportAnimation`（Task 3，仅类型）。
- Produces（`CanvasModel.swift`）：

```swift
struct ViewportRequest: Equatable { var viewport: Viewport; var animated: Bool; var token: Int }
@MainActor final class ZoomIndicator: ObservableObject {
    @Published private(set) var scale = 1.0
    private(set) var viewport = Viewport()          // 实时视角，不发布
    func update(_ viewport: Viewport)               // 存 viewport；scale 变化 ≥0.5% 时才发布
}
```

`AtlasStore` 改动：
- 删除 `@Published interactingFrameID`；新增 `@Published var selection: Set<String> = []`、`@Published var tool: CanvasTool = .move`、`@Published private(set) var viewportRequest = ViewportRequest(viewport: Viewport(), animated: false, token: 0)`、`@Published private(set) var positionsToken = 0`、`let zoomIndicator = ZoomIndicator()`。
- `viewport` 保留为已停下的视角（不再 `@Published`）。
- `func viewportSettled(_ v: Viewport)`：写 `viewport`、`zoomIndicator.update`、`scheduleSave()`。
- `func framesMoved(_ moved: [String: Point])`：合并进 `positions`，`scheduleSave()`；不改 `positionsToken`。
- `func request(_ v: Viewport, animated: Bool)`（private）：token+1，同时写 `viewport` 与 `zoomIndicator`。
- `fitAll(animated: Bool = true)`、`focusFrame(_:)`、`zoomToSelection()`（选择为空时等同 `fitAll`）、`zoom(_:)`（以 `zoomIndicator.viewport` 为基准、画布中心为锚点）全部走 `request`。`select(project)` 与 `reset()` 用 `animated: false`，并 `positionsToken += 1`、`selection = []`。
- 删除 `updateViewport`、`moveFrame`。

`NativeCanvas` 参数改为：`project, positions, positionsToken, viewportRequest, selection, tool, reloadToken, zoomIndicator`，回调 `onViewportSettled(Viewport)`、`onFramesMoved([String: Point])`、`onSelectionChange(Set<String>)`、`onToolChange(CanvasTool)`、`onFocusFrame(String)`、`onSizeChange(CGSize)`。`AtlasCanvasView.update` 只在项目变化、`positionsToken`、`viewportRequest.token`、`reloadToken` 变化时动作（本任务里 request 一律立即应用，动画在 Task 10）。本任务内画布保持旧输入代码，仅把“交互中”判定替换为 `selection.count == 1 && selection.contains(id)`。

UI：删除 `WorkspaceView` 顶部“正在交互”横条、`PreviewFrameView` 的 `interactionButton`、`AtlasApp` 菜单“退出网页交互”。工具栏缩放百分比改读 `@ObservedObject zoomIndicator`（抽出 `ZoomLabel` 子视图）。

- [ ] **Step 1: 写测试**（`StoreTests.swift`，沿用 `ViewportTests` 中的 Project 构造，抽到测试内私有函数 `sampleProject(id:)`）
  - `fitAllIssuesAnimatedRequestWithNewToken`：`select` 后记录 token，`fitAll()` → token +1 且 `animated == true`。
  - `selectingProjectResetsSelectionAndBumpsPositionsToken`。
  - `settledViewportIsSavedAndReflected`：`viewportSettled(v)` 后 `store.viewport == v` 且 `zoomIndicator.scale == v.scale`。
  - `framesMovedMergesPositions`。
  - `zoomToSelectionFallsBackToFitAll`。
  - 保留并更新 `resizingAfterSwitchingToANewProjectPreservesTheUsersViewport`（API 不变，应继续通过）。
- [ ] **Step 2:** `--filter StoreTests` 预期 FAIL。
- [ ] **Step 3:** 实现上述 Store、桥与 UI 改动。
- [ ] **Step 4:** `pnpm test:native` 全绿；`pnpm dev` 启动后人工确认：工具栏缩放、⌘0、底部聚焦按钮可用；无“进入交互”按钮。
- [ ] **Step 5:** 提交 `refactor(native): settle-based canvas data flow`。

### Task 8: 画布指针输入、覆盖层与撤销

**Files:**
- Create: `native/Sources/AtlasApp/CanvasOverlay.swift`
- Modify: `native/Sources/AtlasApp/CanvasView.swift`、`PreviewFrameView.swift`
- Test: `native/Tests/AtlasAppTests/CanvasInputTests.swift`（新建）

**Interfaces:**
- Consumes: `CanvasInteraction`、`InteractionEffect`、`HitTarget`、`InteractionContext`（Task 5）；Task 7 回调。
- Produces:
  - `CanvasOverlay: NSView`（`hitTest` 恒返回 nil），方法 `func render(viewport: Viewport, frames: [String: Rect], selection: Set<String>, active: String?, hover: String?, marquee: Rect?, guides: [Guide])`。用 CAShapeLayer：选中 2pt `controlAccentColor`，悬停 1pt 同色，活动画框额外外描边，框选半透明强调色填充 + 1pt 描边，参考线 1pt `systemRed`；外观变化时更新颜色。
  - `PreviewFrameView.isReady: Bool`（`didFinish` 后 true，失败/重新加载时 false）；去掉 `selected`、`interactive` 的绘制，只保留标题与边框分隔线；`retryButton`、`externalButton` 仍可点击。
  - `AtlasCanvasView` 新增 `func hitTarget(at screen: NSPoint) -> HitTarget`（按 z 序从上到下查找画框；标题区 = 顶部 `CanvasGeometry.headerHeight` 世界单位）。

实现要点：
- `AtlasCanvasView.hitTest`：落在画框的 `retryButton/externalButton` 上返回按钮；`CanvasInteraction.pageReceivesPointer` 为真返回 `super.hitTest`（webView 子树）；否则返回 `self`。`CanvasWorldView` 与 `PreviewFrameView` 不再处理鼠标事件。
- `mouseDown/Dragged/Up`、`otherMouseDown/Dragged/Up`（中键）、`mouseMoved`（`NSTrackingArea` 更新悬停）把事件转给 `CanvasInteraction`，统一由 `apply(_ effects: [InteractionEffect])` 执行：`select` → 更新选择、覆盖层、`onSelectionChange`；`moveFrames` → 改画框 origin（不回调）；`commitMove` → `onFramesMoved(to)` + 注册撤销；`pan` → 更新视角（Task 10 前沿用现有 `applyViewport`）；`focus` → `onFocusFrame`。
- 撤销：`registerMove(from:to:)` 用 `window?.undoManager`，动作名“移动画框”，撤销时应用 `from` 并注册反向。项目切换与 `positionsToken` 变化时 `undoManager?.removeAllActions(withTarget: self)`。
- `releaseHeldInput()` 额外调用 `interaction.cancel()` 并 `apply`。
- Esc 网页桥（`atlasExit`）改为：选择清空并 `window?.makeFirstResponder(canvas)`。
- 画框辅助功能标签附加“，已选中”/“，活动”。

- [ ] **Step 1: 写测试**（建 `NSWindow` + `AtlasCanvasView`，`update` 传入两画框项目；用 `NSEvent.mouseEvent(with:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:)` 合成事件直接调用 `mouseDown` 等）
  - `clickSelectsAndReportsSelection`：点画框 a 内容 → `onSelectionChange` 收到 `["a"]`；`hitTest` 在 a 内容处返回 `canvas`（未加载完成）。
  - `dragCommitsAndUndoRestores`：拖动 a 100 点 → `onFramesMoved` 收到新位置；`window.undoManager?.undo()` → 再次回调原位置；`redo()` 回到新位置。
  - `focusLossCommitsMove`：拖动中 post `NSWindow.didResignKeyNotification` → 恰一次 `onFramesMoved`。
  - `switchingProjectClearsUndo`：拖动后用另一项目 `update` → `undoManager.canUndo == false`。
- [ ] **Step 2:** `--filter CanvasInputTests` 预期 FAIL。
- [ ] **Step 3:** 实现。
- [ ] **Step 4:** `pnpm test:native` 全绿；`pnpm dev` 人工确认：首次点击只选中、再次点击可操作网页、框选、Shift 多选、整体移动、红色参考线、⌘Z/⇧⌘Z。
- [ ] **Step 5:** 提交 `feat(native): figma-style selection, marquee, snapping and undo`。

### Task 9: 滚动路由、工具与快捷键

**Files:**
- Modify: `native/Sources/AtlasApp/CanvasView.swift`、`WorkspaceView.swift`
- Test: `native/Tests/AtlasAppTests/CanvasInputTests.swift`

**Interfaces:**
- Consumes: `ScrollRouter`（Task 4）、`CanvasTool`、Task 7 的 `onToolChange`、`onFocusFrame`；Store 的 `fitAll()`、`zoomToSelection()`、`zoom(_:)` 通过新回调 `onCommand(CanvasCommand)` 调用。
- Produces: `enum CanvasCommand: Equatable { case fitAll, zoomToSelection, actualSize }`（定义于 `CanvasModel.swift`）；`NativeCanvas` 新增 `onCommand` 参数，`WorkspaceView` 映射到 store。

实现要点：
- 本地事件监视器中的 `.scrollWheel`：映射 `phase/momentumPhase` 到 `ScrollPhase`（两者皆空 → `.discrete`），`overActivePage` = 指针命中活动画框内容；`zoomModifier` = ⌘ 或 ⌃。目标为 `.page`：指针在该 webView 上则原样返回事件，否则调用活动 webView 的 `scrollWheel(with:)` 并吞掉；目标为 `.canvas`：调用画布滚动/缩放并吞掉。
- `keyDown`（画布为第一响应者时）：keyCode 18/19/29 + Shift → `onCommand(.fitAll/.zoomToSelection/.actualSize)`；`v`/`h` → `onToolChange`；方向键移动选择（10/100），整次按键作为一步撤销并 `onFramesMoved`；Return 唯一选中且就绪 → `makeFirstResponder(webView)`；Esc → 清空选择；⌘A → 选中全部。
- 抓手工具下光标为 `openHand`，拖动中 `closedHand`。
- 工具栏新增分段 `Picker`（“移动 V” `cursorarrow` / “抓手 H” `hand.raised`）绑定 `store.tool`。底部提示改为 spec 文案：`点选画框后可直接操作 · 空格拖动平移 · ⌘滚轮或捏合缩放 · Shift+1 适应全部`。

- [ ] **Step 1: 写测试**
  - `arrowKeysNudgeSelectionAndUndoAsOneStep`：选中 a，合成右方向键 keyDown → 位置 x +10，Shift → +100；`undo()` 一次只撤销最近一次。
  - `shiftDigitsIssueCommands`：合成 Shift+1/2/0 → `onCommand` 依次收到三种命令。
  - `toolKeysReportToolChange`：`v`、`h`。
- [ ] **Step 2–4:** FAIL → 实现 → `pnpm test:native` 全绿；`pnpm dev` 人工确认触控板惯性滑过活动画框不切换目标、活动画框内滚动网页。
- [ ] **Step 5:** 提交 `feat(native): scroll routing, tools and figma shortcuts`。

### Task 10: 渲染性能与动画

**Files:**
- Create: `native/Sources/AtlasApp/CanvasGrid.swift`
- Modify: `native/Sources/AtlasApp/CanvasView.swift`
- Test: `native/Tests/AtlasAppTests/CanvasInputTests.swift`

**Interfaces:**
- Consumes: `ViewportAnimation`（Task 3）、`ViewportRequest`、`ZoomIndicator`（Task 7）。
- Produces: `CanvasGrid: CALayer`，`func update(viewport: Viewport, bounds: CGRect)`。实现为两级 `CAReplicatorLayer`（x 方向复制一个 1.5pt 圆点，y 方向复制该行），复制间距 = `32 * scale`，平移只改根层 `position` 的相位（`viewport.x/y` 对间距取余），不重建子层；间距 < 8 时 `isHidden = true`；颜色取 `separatorColor` 55% 透明度，外观变化时更新。`AtlasCanvasView` 内部 `committedViewport` 与 `liveViewport`。

实现要点：
- 视图层级：`AtlasCanvasView` → `gridLayer`（layer）→ `zoomHost: NSView`（`wantsLayer`，承载 `world`）→ `CanvasOverlay`。删除 `draw(_:)` 中逐点 `NSBezierPath`。
- 平移：直接改 `world.bounds.origin` 并同步 `committedViewport`（便宜）。
- 缩放（捏合、⌘ 滚轮、动画、请求的 animated）：只设 `zoomHost.layer?.sublayerTransform`（由 committed → live 的缩放与平移），并在 `CATransaction.setDisableActions(true)` 中更新；停下时（捏合 `phase == .ended`、⌘ 滚轮空闲 150ms、动画结束）提交到 `world.bounds` 并重置变换，然后 `onViewportSettled(live)`。
- 任何 `mouseDown`/`otherMouseDown`/`keyDown` 先调用 `commitPendingZoom()`；动画中有新输入 → 停止动画，从当前 `liveViewport` 继续。
- 动画驱动用 `displayLink(target:selector:)`（macOS 14 NSView API），时长 `ViewportAnimation.duration`。
- `zoomIndicator.update(liveViewport)` 以 ≤30Hz 节流。
- 调试：环境变量 `UI_ATLAS_FRAME_LOG=1` 时，用同一 display link 统计帧间隔 >25ms 的次数，每秒向 stderr 打印 `[frame] hitches=N frames=M`。
- 实测项：真实案例中缩放停下提交时若明显闪烁，改为手势中每约 100ms 提交一次，并在 `docs/native-verification.md` 记录结论。

- [ ] **Step 0: 先加帧日志并测基线**：只实现 `UI_ATLAS_FRAME_LOG` 统计（display link），在尚未改渲染的代码上用 `UI_ATLAS_FRAME_LOG=1 pnpm dev` 做 10 秒连续平移 + 10 秒捏合，记录 hitches 数作为基线。
- [ ] **Step 1: 写测试**
  - `pointerDownCommitsPendingZoom`：调用 `magnify`（phase `.changed`）后 `world.bounds` 未变；随后 `mouseDown` → `world.bounds` 反映新缩放且 `onViewportSettled` 被调用一次。
  - `animatedRequestSettlesAtTarget`：下发 `animated: true` 请求，直接调用测试钩子 `advanceAnimation(to: 1)` → `onViewportSettled` 收到目标视角。
  - `gridHidesWhenDense`：`scale = 0.2` 时 `gridLayer.isHidden == true`，`scale = 1` 时 false。
- [ ] **Step 2–4:** FAIL → 实现 → `pnpm test:native` 全绿。
- [ ] **Step 5:** 用同一操作再测一次 hitches 数，与 Step 0 基线对比，结果留待 Task 11 写入验证记录。
- [ ] **Step 6:** 提交 `perf(native): layer-backed grid, transform zoom and animated viewport`。

### Task 11: 文档与真实 App 验收

**Files:**
- Modify: `docs/macos.md`（“画布操作”整节按 spec 第 1 节重写）、`GLOSSARY.md`（“交互模式”替换为“**活动画框**：唯一选中且已加载的画框，指针与键盘输入直接交给其网页。”）、`docs/native-verification.md`（新增“Figma 式交互验收”小节）、`README.md`（“如何操作”中原生相关描述若有冲突则更正）

- [ ] **Step 1:** 更新文档。
- [ ] **Step 2:** 运行完整门禁：`pnpm test:native`、`pnpm check`、`pnpm build:native`、`codesign --verify --deep --strict dist/界面图鉴.app`，全部通过。
- [ ] **Step 3:** 用 `open dist/界面图鉴.app` 逐项验收 spec 第 4 节“真实 App 验收”清单，浅色、深色、约 940×672 窄窗口各截图存入 `docs/evidence/`（`native-figma-light.png`、`native-figma-dark.png`），帧间隔对比写入验证记录。
- [ ] **Step 4:** 本地审查（Heavy 档：Standards 与 Spec 两个独立审查），修复有效发现。
- [ ] **Step 5:** 提交 `docs: document figma-style canvas interaction and acceptance`；更新 `.scratch/figma-canvas/spec.md` 的 `Status:` 为“已实现”。
