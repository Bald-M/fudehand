# 原生设计文档与 Figma 式工作流（#46）

日期：2026-11-17。需求来源：Issue #46。用户以 `/goal` 下达，要求自主推进；本文中标注“实现方决定”的条目是实现方按 Issue 意图做出的取舍，未经单独确认。

## 意图

ui-atlas 从“在画布上展示网页作品”改为“原生的 AI 设计工具”：画布上放的是图层数据，Agent 和人编辑同一份设计文档，画布用原生方式实时渲染，设计稿保存为 ui-atlas 自己的工程文件。目的是去掉每个作品一套前端工程、常驻 Node/Vite/WebKit 进程的重链路，并让 Agent 直接创建和修改界面元素，而不是改网页源码。

## 目标

- 设计文档是一棵图层树：画框、矩形、椭圆、文字、图片、分组；画框支持自动布局；所有图层支持填充、描边、圆角（适用的类型）、透明度、显示/隐藏、锁定。
- 画布直接渲染图层数据，任何修改立即可见，不需要编译，不依赖 Node 或网页服务。
- Agent 经 MCP 工具读取文档结构、增删改节点、截图核对；所有修改经控制通道交给 App，App 是文档状态的唯一持有者。
- 人工编辑：图层面板（层级、显示/隐藏、锁定、重命名）、属性面板（位置、尺寸、填充、描边、文字、自动布局），画布上可选中、移动、缩放图层。
- 工程文件：新建、打开、保存、另存为；格式为带版本号的公开 JSON。启动时是空白文档。
- 撤销/重做覆盖人工与 Agent 编辑，共用一条历史。
- 移除网页作品链路：`WKWebView` 画框、Node 预览启动器、`catalog.json`、`examples/`。

## 非目标

与 Issue 相同：不与 Figma 互通，不做多人协作、原型交互、组件/变体/变量、代码生成，不保留网页作品。另外本期不做：旋转、渐变与多重填充、阴影与模糊、矢量路径与布尔运算、画布上直接编辑文字（文字在属性面板编辑）、自动布局子项拖动重排（用图层面板或 Agent 调整顺序）。

## 反目标

- Agent 修改需要重启 App、重新加载或编译才能看到——这等于没做。
- 文档状态出现第二个持有者（例如 Node 端缓存一份文档再写回），导致人工修改与 Agent 修改互相覆盖。
- 平移、缩放因图层数增加而明显掉帧。

## 方案

考虑过的做法：

1. **Core Animation 图层树（采用）**：每个设计节点对应一个 `CALayer`（形状用 `CAShapeLayer`，文字用 `CATextLayer`，图片设置 `contents`），按节点 id 增量更新。平移、缩放沿用现有画布的 `world.bounds` 与 GPU 变换，矢量与背景由 Core Animation 按任意缩放渲染；文字与图片在缩放稳定后按缩放比例更新 `contentsScale`。截图用同一套构建函数离屏 `render(in:)`。
2. **单个 NSView 用 Core Graphics 整体重绘**：实现最简单，但每次平移/缩放和每次修改都要重绘全部节点，100 个以上图层时难以保持流畅。
3. **SwiftUI `Canvas` 或 SwiftUI 视图树**：与现有 AppKit 画布（输入路由、视口动画、框选）割裂，需要重写交互层，收益不明显。

文档状态放在哪里：

- **App 持有（采用）**：`AtlasCore` 中的纯 Swift 文档模型与编辑器，App 的 `AtlasStore` 持有唯一实例；Agent 通过控制通道发送命令。符合 Issue “App 是文档状态的唯一持有者”。
- Node 端持有文档、App 只渲染：会出现两个持有者，被 Issue 排除。

## 设计

### 文档格式（`AtlasCore/DesignDocument.swift`）

扩展名 `.uiatlas`，内容为 UTF-8 JSON：

```json
{
  "format": "ui-atlas.design",
  "version": 1,
  "nodes": [
    { "id": "screen", "type": "frame", "name": "首页", "x": 0, "y": 0, "width": 390, "height": 844,
      "fill": "#FFFFFF", "cornerRadius": 0, "clipsContent": true,
      "layout": { "direction": "vertical", "spacing": 12, "padding": { "top": 16, "right": 16, "bottom": 16, "left": 16 },
                  "align": "start", "crossAlign": "stretch" },
      "children": [
        { "id": "title", "type": "text", "name": "标题", "x": 16, "y": 16, "width": 120, "height": 28,
          "text": { "content": "今日计划", "fontSize": 22, "fontWeight": 600, "color": "#111111", "align": "left", "autoResize": "height" },
          "sizing": { "horizontal": "fill", "vertical": "hug" } }
      ] }
  ]
}
```

- 所有坐标相对父节点，单位为点；顶层节点相对画布原点。数组顺序即层叠顺序，后者在上。
- 通用字段：`id`（文档内唯一）、`type`、`name`、`x`、`y`、`width`、`height`、`visible`（默认 true）、`locked`（默认 false）、`opacity`（0–1，默认 1）、`fill`（`#RRGGBB` 或 `#RRGGBBAA`，可省略表示无填充）、`stroke`（`{color, width}`，可省略）、`sizing`（`{horizontal, vertical}`，取值 `fixed`/`hug`/`fill`，默认 fixed）。
- `cornerRadius`：frame、rectangle、image。`clipsContent`：frame（默认 true）。`children`：frame、group。
- `text`：`content`、`fontSize`、`fontWeight`（100–900）、`fontFamily`（可省略，用系统字体）、`color`、`align`（left/center/right）、`lineHeight`（可省略，倍数）、`autoResize`（`none`/`height`/`width-and-height`）。
- `image`：`data`（base64 的 PNG 或 JPEG）与 `fit`（`fill`/`fit`/`stretch`）。
- `layout`（frame）：`direction`（horizontal/vertical）、`spacing`、`padding`、`align`（主轴 start/center/end/space-between）、`crossAlign`（start/center/end/stretch）。
- 读取时校验：`format` 必须匹配；`version` 大于当前支持版本时拒绝并提示“文件由更新版本的 ui-atlas 创建”；id 重复、类型与字段不匹配、数值非有限或为负的尺寸都报出具体路径。写入使用排序键、两空格缩进，便于 diff。

### 布局（`AtlasCore/DesignLayout.swift`）

布局结果直接写回节点的 `x/y/width/height`（与 Figma 一样，文件中保存的是计算后的几何），渲染器只读这些值。每次编辑后整体重新布局一次，文字尺寸由 App 注入的测量函数提供（`AtlasCore` 不依赖 AppKit）：

1. 自底向上：文字按 `autoResize` 测量；`hug` 的自动布局画框按子项尺寸、间距与内边距求尺寸；分组收缩为子项并集（分组原点移到并集左上角，子项相应平移）。
2. 自顶向下：自动布局画框按主轴分配 `fill` 子项尺寸、交叉轴 `stretch`/`fill` 设为内容区尺寸，再按 `align` 摆放子项；然后递归处理子项。
3. 宽度变化会影响 `autoResize: height` 文字的高度，因此整个过程运行两遍。

不参与自动布局的父节点里，子项 `fill` 与 `hug`（非文字、非自动布局画框）按 fixed 处理。

### 编辑器与撤销（`AtlasCore/DesignEditor.swift`）

`DesignEditor` 是值类型，持有文档和历史快照：

- `perform(_ name:, change:)`：记录修改前的快照，执行修改，重新布局；文档有变化时压入撤销栈并清空重做栈。一次 Agent 命令（包括一次创建整棵子树）就是一步撤销。
- 画布拖动和缩放把手：`beginGesture()` 记录快照，过程中只修改文档不记录，`endGesture(name:)` 压入一步。
- 属性面板连续调整（如颜色取色器）带合并键，相同键的连续修改合并为一步。
- 节点操作：插入（可带嵌套子节点，未给 id 时生成 8 位随机 id）、按补丁更新（嵌套对象逐字段合并）、删除、移动/重新指定父节点（保持画布上的绝对位置）、设置可见/锁定。
- 记录修订号；保存时记下已保存的修订号，用于“已编辑”标记。

### 控制通道与 MCP 工具

控制协议（行分隔 JSON，沿用现有 socket 与安全约束）的命令替换为：

| 命令 | 作用 |
| --- | --- |
| `get_state` | 文件名、路径、是否已编辑、选择、视口、可否撤销/重做、顶层节点摘要 |
| `get_document` | 完整图层树；图片数据以 `"<N 字节>"` 代替 |
| `get_node` | 单个节点子树 |
| `create_node` | `{parent?, index?, node}`，`node` 可含嵌套 `children`；返回新建 id |
| `update_node` | `{id, changes}`，部分字段补丁 |
| `delete_nodes` | `{ids}` |
| `move_node` | `{id, parent?, index?}`，`parent` 为 null 表示顶层 |
| `select` | `{ids}` |
| `undo` / `redo` | 撤销、重做一步 |
| `new_document` / `open_document` / `save_document` | 新建（有未保存修改时拒绝，除非 `discard: true`）、打开 `{path}`、保存 `{path?}` |
| `focus_node` / `fit_all` / `zoom` | 视口 |
| `node_snapshot` | `{id, scale?}`，返回该节点渲染的 PNG |

字段校验只在 Swift 一处（`AtlasCore/DesignPatch.swift`）。`scripts/atlas-tools.mjs` 只把参数转发给控制通道，MCP 工具名为 `design_*` 与 `canvas_*`；图片可以传 `imagePath`，由 Node 端读成 base64 再转发。harness 的系统提示改为设计助手。

### App

- `AtlasStore` 持有 `DesignEditor`、当前文件 URL、选择和视口请求；启动时新建空白文档，不启动任何 Node 进程（对话面板只在发送消息时按需启动 harness）。
- `DesignRenderer` 把文档同步到 `CALayer` 树，按 id 复用图层，只更新变化的属性；隐藏的节点不渲染；画框 `clipsContent` 时裁剪子层。
- 画布交互（Figma 式）：
  - 点击选中顶层画框里的直接子项；点击画框名称标签或画框空白处选中画框；分组点击选中整个分组，双击进入下一层；⌘ + 点击选中最深的图层。锁定和隐藏的图层不能在画布上点中。
  - 拖动移动选中图层（3pt 阈值，吸附到兄弟图层边缘与中线，⌃ 关闭吸附）；自动布局画框里的子项不随拖动移动。
  - 单选时显示 8 个缩放把手，拖动改变尺寸并把对应方向设为 fixed。
  - 拖动空白框选顶层图层，Shift 追加。
  - 工具：移动 V、抓手 H、画框 F、矩形 R、椭圆 O、文字 T；创建工具在画布上拖出尺寸（单击用默认尺寸），落在起点所在的顶层画框内，创建后回到移动工具。
  - 键盘：方向键移动 1，Shift + 方向键移动 10；Delete/Backspace 删除；Esc 选中父图层，无父图层时取消选择；⌘A 选中当前层级全部；平移缩放沿用现有规则。
- 图层面板（左侧栏）：缩进树，类型图标，双击重命名，眼睛与锁按钮，点击选中、⌘/Shift 多选，与画布选择同步。
- 右侧检查器分“设计 / 对话”两页。设计页：未选中时显示文档信息；单选时显示名称、X/Y/W/H、尺寸模式、透明度、圆角、填充、描边、文字、自动布局、裁剪内容、图片适应方式与替换图片；多选时显示数量与透明度。
- 菜单：文件（新建 ⌘N、打开 ⌘O、保存 ⌘S、另存为 ⇧⌘S）、编辑（撤销 ⌘Z、重做 ⇧⌘Z；文字输入框有焦点时交给输入框）、画布（缩放）。新建、打开或退出时有未保存修改则询问保存。
- 窗口标题显示文件名，未保存时带“已编辑”。

### 移除

删除 `PreviewFrameView`、`PreviewSession`、`FramePageScripts`、`ThumbnailCache`、`Catalog`、`LayoutStore`、`ScrollRouting`（滚动永远平移画布）、`SidebarOrdering`、`FrameConsole`，以及 `scripts/launcher.mjs`、`native-preview.mjs`、`preview-gate.*`、`catalog.json`、`tests/fixtures/catalog-conformance.json`、`examples/` 和对应测试。`pnpm check` 改为只运行 Vitest（不再有示例需要类型检查和构建）。`native-build.mjs` 仍写入 `workspace.json`，供对话面板找到 harness 与 Node。

## 留给实现方

- 控件样式、图标、默认颜色与默认尺寸。
- 文字测量与 `CATextLayer` 渲染的细节对齐。
- 自动布局中的边界情况（例如 hug 父节点内的 fill 子项按 fixed 处理）。

## 验收

见 Issue #46 的验收标准；另外：

- `AtlasCore` 单元测试覆盖文档读写与版本校验、补丁校验、布局、编辑与撤销、画布交互状态机。
- `AtlasApp` 测试覆盖控制命令分发、渲染器增量更新和截图。
- Node 测试覆盖 MCP 工具转发与 `imagePath` 读取。
- 真实 App 中用 MCP 工具逐步搭建移动端画框，并截取浅色、深色截图放入 `docs/evidence/`。
