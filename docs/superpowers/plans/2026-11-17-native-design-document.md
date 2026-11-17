# 原生设计文档 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把画布从网页作品改为 App 持有、Core Animation 渲染的设计文档，人和 Agent 共同编辑，可保存为 `.uiatlas` 工程文件。

**Architecture:** `AtlasCore` 新增纯 Swift 的文档模型、补丁校验、布局与带历史的编辑器；`AtlasApp` 用 `DesignRenderer` 把文档同步到 CALayer 树，画布交互改为面向图层，SwiftUI 提供图层面板与属性面板；控制通道命令改为设计命令，`atlas-tools.mjs` 只做转发。

**Tech Stack:** Swift 6 工具链（Swift 5 语言模式）、AppKit/SwiftUI/Core Animation/CoreText、Node 22 + Vitest。

**Spec:** `docs/superpowers/specs/2026-11-17-native-design-document-design.md`

## Global Constraints

- macOS 14+，不引入第三方 Swift 包；`AtlasCore` 不依赖 AppKit。
- 文档格式：`"format": "ui-atlas.design"`，`"version": 1`，扩展名 `.uiatlas`，坐标相对父节点。
- 文案、错误信息为中文；字段校验只在 Swift 一处。
- 启动不启动任何 Node 进程；控制通道 socket 与权限约束不变。
- 不要同时在同一 scratch 目录运行两个 Swift 构建（本工作树用 `UI_ATLAS_SWIFT_SCRATCH=/private/tmp/ui-atlas-46-scratch`）。

## Review Focus

- 打开格式错误、版本更高或 id 重复的文件：报出具体原因，当前文档保持不变（Task 1 测试）。
- Agent 补丁含未知字段、错误类型或作用于不支持该字段的类型（如给 ellipse 设 `layout`）：拒绝整次命令，文档与历史不变（Task 2 测试）。
- 删除含选中子项的父节点、移动节点到自身后代：选择被清理；移动被拒绝（Task 3 测试）。
- 有未保存修改时新建/打开/退出：询问保存，Agent 的 `new_document` 未带 `discard` 时拒绝（Task 7 测试）。
- 文本 `autoResize: height` 处于 fill 宽度的自动布局中：宽度变化后高度随之更新（Task 2 布局测试）。

---

### Task 1: 文档模型与文件读写

**Files:** Create `native/Sources/AtlasCore/DesignDocument.swift`, `native/Tests/AtlasCoreTests/DesignDocumentTests.swift`

**Interfaces — Produces:**
- `DesignColor`（`hex: String` 编解码，`r,g,b,a: Double`）、`DesignStroke {color, width}`、`DesignText {content, fontSize, fontWeight, fontFamily?, color, align, lineHeight?, autoResize}`、`DesignImage {data: Data, fit}`、`AutoLayout {direction, spacing, padding: EdgeInsets, align, crossAlign}`、`Sizing {horizontal, vertical}`。
- `enum NodeType: String { frame, rectangle, ellipse, text, image, group }`，`struct DesignNode: Equatable`（spec 中全部字段，`children: [DesignNode]`）。
- `struct DesignDocument: Equatable { var nodes: [DesignNode]; static let formatVersion = 1; static func decode(_ data: Data) throws -> DesignDocument; func encoded() throws -> Data }`；错误类型 `DesignError: LocalizedError { message }`。

- [ ] 测试：往返编码保持相等；`version: 2` 报“文件由更新版本的 ui-atlas 创建”；`format` 错误、id 重复（报出 id）、text 节点缺 `text` 时报错；编码结果键有序。
- [ ] 实现并通过：`swift test --filter AtlasCoreTests.DesignDocumentTests`。

### Task 2: 补丁校验与布局

**Files:** Create `AtlasCore/DesignPatch.swift`, `AtlasCore/DesignLayout.swift`, tests `DesignPatchTests.swift`, `DesignLayoutTests.swift`

**Interfaces — Produces:**
- `DesignPatch.node(from json: [String: Any], defaultType:) throws -> DesignNode`（新建，含嵌套 children、默认值）；`DesignPatch.apply(_ changes: [String: Any], to node: inout DesignNode) throws`（嵌套对象逐字段合并，`null` 清除可选字段）；`DesignPatch.json(_ node:, includeImageData: Bool) -> [String: Any]`。
- `typealias TextMeasure = (DesignText, _ maxWidth: Double?) -> Size`；`DesignLayout.apply(to nodes: inout [DesignNode], measure: TextMeasure)`。

- [ ] 测试补丁：未知字段报“不支持字段：foo”；`opacity: 2` 报范围错误；ellipse 设 `layout` 拒绝；`text: {fontSize: 20}` 只改字号；`fill: null` 清除。
- [ ] 测试布局：竖向 hug 画框（padding 16、spacing 12、两个 50 高子项）高度为 144；fill 子项平分剩余宽度；crossAlign stretch；space-between；分组收缩为子项并集且原点规整；fill 宽文字 `autoResize: height` 在父宽变化后高度随之变化（测量函数按宽度返回行数）。
- [ ] 实现并通过。

### Task 3: 编辑器与历史

**Files:** Create `AtlasCore/DesignEditor.swift`, test `DesignEditorTests.swift`

**Interfaces — Produces:** `struct DesignEditor { var document; var revision: Int; var canUndo/canRedo; init(document:, measure:); mutating func perform<T>(_ name: String, coalescing: String? = nil, _ change: (inout DesignDocument) throws -> T) rethrows -> T; beginGesture(); endGesture(_ name:); undo() -> Bool; redo() -> Bool; func node(_ id:) -> DesignNode?; func parentID(of:) -> String??; func worldRect(_ id:) -> Rect?; func path(to id:) -> [String] }`；`extension DesignDocument { mutating func insert(_ node:, parent: String?, index: Int?) throws; update(_ id:, _ change: (inout DesignNode) throws -> Void) throws; delete(_ ids: Set<String>); move(_ id:, parent: String?, index: Int?) throws; func allIDs() -> Set<String>; static func newID(existing:) -> String }`。

- [ ] 测试：一次 perform 一步撤销、redo 恢复、新操作清空 redo；无变化不入栈；相同 coalescing 键合并；手势 begin/end 一步；移动到自身后代报错；重新指定父节点保持世界坐标；revision 递增。
- [ ] 实现并通过。

### Task 4: 控制协议与交互状态机

**Files:** Modify `AtlasCore/ControlProtocol.swift`, `AtlasCore/CanvasInteraction.swift`; delete `Catalog.swift`, `LayoutStore.swift`, `ScrollRouting.swift`, `SidebarOrdering.swift`, `FrameConsole.swift` 及其测试；更新 `ControlProtocolTests`, `CanvasInteractionTests`

**Interfaces — Produces:**
- `ControlCommand`: `getState, getDocument, getNode(String), createNode(parent: String?, index: Int?, node: JSONObject), updateNode(String, JSONObject), deleteNodes([String]), moveNode(String, parent: String?, index: Int?), select([String]), undo, redo, newDocument(discard: Bool), openDocument(String), saveDocument(String?), focusNode(String), fitAll, zoom(Double), nodeSnapshot(String, scale: Double)`；`JSONObject` 为 `Sendable` 包装的 `[String: Any]`（以 JSON Data 存储，便于 Equatable）。
- `HitTarget: empty | node(String) | label(String) | handle(String, ResizeHandle)`；`CanvasTool: move, hand, frame, rectangle, ellipse, text`；新增效果 `resize(id, Rect)`, `commitResize(id)`, `create(NodeType, Rect, parent: String?)`, `beginGesture`；`InteractionContext.frames` 改名 `rects`，增加 `movable: Set<String>`。

- [ ] 测试协议：每个新命令解析、缺参与类型错误；测试交互：拖把手发出 resize、创建工具拖出矩形、不可移动的子项拖动不移动。
- [ ] 实现并通过 `pnpm test:native` 中 AtlasCoreTests。

### Task 5: 渲染器与画布

**Files:** Create `AtlasApp/DesignRenderer.swift`, `AtlasApp/TextMetrics.swift`; rewrite `CanvasView.swift`, `CanvasOverlay.swift`, `NativeCanvas.swift`; delete `PreviewFrameView.swift`, `FramePageScripts.swift`, `ThumbnailCache.swift`, `PreviewSession.swift`；tests `DesignRendererTests.swift`、改写 `CanvasInputTests.swift`

**Interfaces — Produces:** `final class DesignRenderer { let root: CALayer; func sync(_ nodes: [DesignNode]); func updateScale(_ zoom: Double); static func snapshotPNG(_ node: DesignNode, scale: Double) throws -> Data }`；`TextMetrics.measure: TextMeasure`；`AtlasCanvasView.update(document:revision:selection:viewportRequest:tool:)`，回调 `onSelect(Set<String>)`, `onEdit(DesignEdit)`（`.move([id: Point]) / .resize(id, Rect) / .create(...) / .delete / .beginGesture / .endGesture(String)`）。

- [ ] 测试：sync 后图层数与可见节点数一致；改一个节点只替换其属性、图层对象复用；隐藏节点无图层；snapshot 尺寸 = 节点尺寸 × scale；画布点击/拖动/把手/创建的端到端输入测试。
- [ ] 实现并通过。

### Task 6: Store、面板、菜单、文件

**Files:** Rewrite `AtlasStore.swift`, `WorkspaceView.swift`, `AtlasApp.swift`, `ControlCommands.swift`; create `LayersPanel.swift`, `InspectorPanel.swift`; modify `ChatSession`/`ChatPanel` 的 root 来源；tests `StoreTests`, `ControlCommandTests`

- [ ] 测试：启动后文档为空、无子进程；控制命令 create/update/undo/redo/save/open 往返；dirty 标记；`new_document` 有未保存修改且无 discard 时报错；打开坏文件保持原文档。
- [ ] 实现并通过 `pnpm test:native`。

### Task 7: MCP 工具与移除网页链路

**Files:** Rewrite `scripts/atlas-tools.mjs`, `scripts/agent-chat.mjs`（系统提示）, tests `atlas-tools.test.ts`, `control-tools.test.ts`, `mcp-server.test.ts`; delete `scripts/launcher.mjs`, `native-preview.mjs`, `preview-gate.*`, `catalog.json`, `examples/`, `tests/launcher*.ts`, `tests/native-launcher.test.ts`, `tests/catalog-conformance.test.ts`, `tests/preview-gate.test.ts`, fixture；`package.json` check 改为 `vitest run`；`pnpm-workspace.yaml` 删除并更新锁文件。

- [ ] 测试：每个 design 工具把参数转发为对应控制命令；`imagePath` 被读成 base64；App 未运行时报“ui-atlas 未运行”。
- [ ] 实现并通过 `pnpm check`。

### Task 8: 文档与验收

- [ ] 更新 `GLOSSARY.md`、`docs/macos.md`、`README.md`、`CLAUDE.md`、`docs/agents/*`。
- [ ] 真实 App：经 MCP 搭建含导航栏、卡片列表、按钮的移动端画框；面板修改后 Agent 读回；撤销/重做；保存-关闭-打开一致；150 个图层下 `UI_ATLAS_FRAME_LOG=1` 平移缩放；浅色/深色截图入 `docs/evidence/`。
