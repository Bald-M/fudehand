# Figma 式画布交互（原生 macOS）

Status: 规格待审阅
日期：2026-11-06
范围：仅原生 App（`native/`）。浏览器兼容版 `apps/atlas` 保持现状。

## 目标

用户反馈原生画布“很不丝滑”，四类问题都要解决：

1. 平移、缩放卡顿；
2. 进入/退出交互模式繁琐；
3. 选择与拖动画框别扭（只能拖标题、无框选/多选、无吸附、无撤销）；
4. 缺少 Figma 习惯的快捷键与过渡动画。

成功标准：交互方式贴近 Figma 设计模式；三画框作品加载后平移与捏合无明显掉帧；无需显式“交互模式”即可操作网页；所有新行为有自动测试或真实 App 验收记录。

非目标：浏览器版改造；画框缩放尺寸（resize）；画框间距标注；多作品同屏；修改 `catalog.json` 格式。

## 1. 交互模型

### 指针

| 操作 | 结果 |
|---|---|
| 点未选画框（标题或内容） | 选中，显示蓝色选框。此次点击不传给网页 |
| 点已选画框内容（仅当它是唯一选中） | 直接交给网页（点击、输入、文字选择）。此画框称为“活动画框” |
| 拖未选画框任意位置 | 移动画框（3pt 阈值后开始）；若它属于多选，则一起移动 |
| 拖已选画框标题栏 | 移动画框 / 整组选择 |
| 拖空白画布 | 框选（与画框矩形相交即选中）；按住 Shift 时在原选择上增减 |
| Shift + 点画框 | 加入或移出选择 |
| 点空白 / Esc | 取消选择。活动画框中的 Esc 先交给网页（沿用现有注入桥），网页未处理且无打开的 dialog 时取消选择 |
| 悬停未选画框 | 显示细描边 |

多选时（≥2 个），画框内容不接收网页输入；点击其中一个画框内容（无 Shift）将选择收缩为该画框，但这次点击仍不传给网页。

加载中或失败的画框可以选择和移动，但不会成为活动画框接收网页输入；“重新加载”按钮与“在浏览器打开”按钮始终可点击。

### 导航（任何状态都可用）

- 空格 + 拖动、鼠标中键拖动、抓手工具 **H** 下的拖动：平移。**V** 回到移动工具（默认）。工具状态在 UI 上通过工具栏分段控件显示。
- 滚轮 / 触控板滚动：起点在活动画框内容内 → 网页滚动；否则平移画布。**每个手势锁定目标**：以 `phase == .began` 时的指针位置决定目标，持续到手势与惯性（momentum）结束；无 phase 的离散滚轮事件逐事件判定。
- ⌘ + 滚轮（或 ⌃ + 滚轮）与触控板捏合：以指针为锚点缩放，任何位置都控制画布（包括活动画框上方）。
- 缩放范围 5%–400%。

### 快捷键

画布持有键盘焦点时：

| 键 | 作用 |
|---|---|
| Shift+1 | 适应全部（动画） |
| Shift+2 | 缩放至选择（动画；无选择时等同适应全部） |
| Shift+0 | 100%，以画布中心为锚点（动画） |
| V / H | 移动工具 / 抓手工具 |
| 方向键 / Shift+方向键 | 选择整体移动 10 / 100 |
| Return | 唯一选中时，把键盘焦点交给该画框网页 |
| Esc | 取消选择 |
| ⌘A | 全选画框 |

菜单命令（任何焦点都可用，沿用并扩展现有命令）：⌘0 适应全部、⌘1 100%、⌘+ / ⌘− 缩放、⌘R 重新加载。⌘Z / ⇧⌘Z：画布焦点时撤销 / 重做画框移动；活动画框网页持有焦点时交给网页（文本撤销）。

### 动画

适应全部、缩放至选择、聚焦画框（底部端类型按钮）、工具栏缩放按钮与上述快捷键，以 200ms ease-out 过渡；缩放在对数空间插值，平移与缩放锚点一致。任何新的指针、滚动、捏合或键盘导航输入立即中断动画并从当前插值状态继续。

### 吸附

拖动画框时，移动集合的外接矩形与其它未选画框的左/中/右边与上/中/下边比较，阈值为 6 屏幕像素（换算为世界单位 `6 / scale`）。每轴取最近的一个吸附，并显示红色参考线（贯穿两个相关矩形的范围）。拖动时按住 ⌃ 关闭吸附。方向键移动不吸附。

### 移除

- “进入交互 / 退出交互”标题按钮、顶部“正在交互”横条、双击内容进入交互、⇧⌘Return；
- 双击标题聚焦改为：双击画框标题 = 缩放至该画框（动画），保留。

## 2. 架构与数据流

### AtlasCore（纯逻辑，可单元测试）

- `CanvasInteraction`：指针状态机。状态：`idle`、`pressed(target, start)`（阈值内）、`movingFrames(ids, origins, start)`、`marquee(start, current, base selection)`、`panning(start, viewport)`。输入：按下 / 拖动 / 抬起事件（屏幕坐标、修饰键、按键类型、命中结果：空白 / 画框内容 / 画框标题 / 控件）、当前选择、当前工具。输出：新状态与效果列表（`select(Set)`、`activate(id)`、`forwardToPage`、`moveFrames([id: Point])`、`marqueeRect(Rect?)`、`pan(Viewport)`、`commitMove(from:to:)`、`guides([Guide])`）。
- `Snapping`：`snap(moving: Rect, others: [Rect], threshold: Double) -> (offset: Point, guides: [Guide])`。
- `ViewportAnimation`：`value(from:to:progress:)`，ease-out，scale 对数插值、同一屏幕锚点保持一致。
- `ScrollRouting`：根据 phase / momentumPhase 与命中结果返回 `page` 或 `canvas`，持有每手势的锁定目标。
- `CanvasGeometry`：`minScale = 0.05`、`maxScale = 4`；“缩放至选择”复用 `fitRects`，结果上限保持 100%（与现有聚焦行为一致）；新增矩形相交与外接矩形辅助。

### AtlasApp（AppKit）

`NativeCanvas.swift`（596 行）拆分为：

- `NativeCanvas.swift`：`NSViewRepresentable` 桥，仅在 token 变化时下发命令。
- `CanvasView.swift`：输入入口，**持有实时 viewport、positions、selection、tool**；把 NSEvent 转为 `CanvasInteraction` 事件并执行效果；键盘快捷键；撤销注册；动画驱动（CVDisplayLink 或 `NSView.displayLink`(macOS 14)）。
- `PreviewFrameView.swift`：仅负责 WKWebView、加载/失败状态、Esc 桥、导航策略与“在浏览器打开”/“重新加载”控件。不再绘制选中态，不再有交互按钮。是否接收网页输入由 `CanvasView` 的命中测试决定（`hitTest` 仅在“活动画框且非空格/抓手/中键”时返回 webView 子树）。
- `CanvasOverlay.swift`：屏幕空间 CAShapeLayer：悬停描边、选框、活动画框描边、框选矩形、吸附参考线。
- `CanvasGrid.swift`：单个 CALayer 使用平铺图案（点阵），平移只改变图案相位，点距 < 8pt 时隐藏。

### 数据流

- 平移与缩放过程中不经过 SwiftUI。`CanvasView` 在“停下”时（手势结束、空闲 150ms、动画结束）回调 `onViewportSettled(Viewport)`；画框移动在拖动结束 / 方向键 / 撤销重做时回调 `onFramesMoved([String: Point])`；选择变化时回调 `onSelectionChange(Set<String>)`。`AtlasStore` 继续去抖保存布局。
- 工具栏缩放百分比由独立 `ZoomIndicator: ObservableObject` 提供，`CanvasView` 以 ≤30Hz 更新；只有工具栏观察它，画布不因此重绘。
- Store → 画布改为一次性命令：`ViewportRequest(target: Viewport, animated: Bool, token: Int)`（适应全部、聚焦、缩放、恢复默认布局），`reloadToken`，项目切换，以及 `positionsToken`（恢复默认布局时整体替换位置）。`updateNSView` 只在 token 或项目变化时动作。
- `AtlasStore.interactingFrameID` 删除；改为 `selection: Set<String>`（画布回传，供 Shift+2、菜单可用性使用）。“活动画框” = 唯一选中。

### 渲染

- 平移：改变 world view 的 `bounds.origin`，不触发网页重排；关闭 CA 隐式动画（`CATransaction.setDisableActions(true)`）。
- 缩放手势进行中（捏合、⌘ 滚轮连续事件、动画中）：只对 world layer 设置 `sublayerTransform`（GPU 缩放），停下时把累计变换提交为 `bounds` 缩放，WebKit 此时清晰重绘。手势中网页可能短暂发虚（与 Figma 一致）。
- 实测验证项：提交时若出现明显闪烁，退回为手势中每约 100ms 提交一次。

### 撤销

使用窗口的 `NSUndoManager`。一次拖动、一次方向键移动、一次多选移动各为一步，动作名“移动画框”。撤销/重做恢复位置并回调 `onFramesMoved`。切换作品、恢复默认布局、重新读取目录时清除该画布注册的撤销项。

## 3. 错误处理与边界

- 窗口失焦或 App 失活时：清除空格按住、平移、框选状态；进行中的画框拖动按当前位置提交为一步撤销并回调。
- 切换作品：清除选择、撤销历史与进行中的动画。重新加载网页保留选择。
- 键盘路由：网页持有焦点时，字母、数字与方向键交给网页；Shift+数字、V/H 仅在画布持有焦点时生效。⌘ 菜单命令始终可用，⌘Z/⇧⌘Z 按焦点路由（见上）。
- 无障碍：画框的辅助功能标签包含“已选中”/“活动”状态；画布帮助文本与底部提示更新为“点选画框后可直接操作 · 空格拖动平移 · ⌘滚轮或捏合缩放 · Shift+1 适应全部”。

## 4. 测试与验收

TDD：先写失败测试，再实现。

AtlasCore 单元测试：

- 状态机：点击未选画框只选中不转发；点击唯一选中画框内容转发网页；3pt 阈值内不移动；Shift 增减选择；框选相交命中与 Shift 叠加；多选整体移动；抓手工具 / 空格 / 中键平移；拖动结束产生一次 `commitMove`。
- 吸附：左/中/右与上/中/下对齐、阈值随缩放换算、取最近候选、⌃ 关闭、无候选时零偏移。
- 滚动路由：began 时锁定、momentum 期间保持、离散滚轮逐事件判定、⌘ 修饰时始终画布。
- 动画插值：端点、ease-out 单调、scale 对数插值、中断后从当前值继续。
- 缩放范围 5%–400%。

AtlasAppTests：store 只在 settle 回调时更新 viewport 与保存；`ViewportRequest` token 递增；撤销 / 重做移动后位置与保存一致；切换作品清空选择。

现有 `pnpm test:native`、`pnpm check` 必须继续通过。

真实 App 验收（写入 `docs/native-verification.md`）：

- 三画框作品加载后连续平移与捏合；用调试开关 `UI_ATLAS_FRAME_LOG=1` 记录帧间隔，对比改造前后的掉帧（>25ms）次数；
- 点击未选画框不触发网页动作，再次点击可操作网页；活动画框内滚动网页、画框外平移；
- 框选、Shift 多选、整体移动、吸附参考线、⌘Z / ⇧⌘Z；
- Shift+1 / Shift+2 / Shift+0 动画与中断；
- 浅色、深色与较窄窗口。

文档：更新 `docs/macos.md` 画布操作、`GLOSSARY.md`（“交互模式”改为“活动画框”）、App 内提示文本。

## 交付

本仓库无远端：在 `claude/figma-canvas-interaction` 分支本地提交，不创建 PR/CI。
