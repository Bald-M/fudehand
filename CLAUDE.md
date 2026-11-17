# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在本仓库中工作提供指引。

ui-atlas 是一个本地 macOS 原生 AI 设计工具：SwiftUI + AppKit 外壳把一份由图层组成的“设计文档”用 Core Animation 渲染在可平移、可缩放的“画布”上，人和 AI Agent 编辑同一份文档，设计稿保存为 `.uiatlas` 工程文件（JSON）。文档、界面文案和错误信息均为中文，术语以 `GLOSSARY.md` 为准。探索代码前先读 `GLOSSARY.md` 和相关的 `docs/adr/`（尤其 ADR 0006）；画布交互行为以 `docs/macos.md` 为权威规范。

## 工作方式：superpowers 技能

本仓库要求使用 [superpowers](https://github.com/obra/superpowers) 技能干活。每次对话开始、做任何事之前（包括提澄清问题、读代码），先调用 `superpowers:using-superpowers`，再按任务调用对应技能并严格遵循；只要有一点可能适用就调用，不要以“任务太简单”为由跳过。常用对应关系：

- 新功能、新行为、任何创作或规划 → 先 `superpowers:brainstorming`，再 `superpowers:writing-plans`
- 按计划实现 → `superpowers:executing-plans`，或在有独立子任务时用 `superpowers:subagent-driven-development`
- 写实现代码前 → `superpowers:test-driven-development`
- Bug、测试失败、异常行为 → 先 `superpowers:systematic-debugging` 再改
- 需要隔离的开发 → `superpowers:using-git-worktrees`
- 声称完成、提交或开 PR 前 → `superpowers:verification-before-completion`
- 完成后请求审查 → `superpowers:requesting-code-review`；收到审查意见 → `superpowers:receiving-code-review`
- 实现完成、决定如何合入 → `superpowers:finishing-a-development-branch`

用户的明确指示和本文件的约定优先于技能流程；只有用户明确说不用时才可跳过。

## 命令

需要 macOS 14+、Swift 6（装 Command Line Tools 即可，不依赖第三方 Swift 包）、Node 22.12+、pnpm 11.7.0。

```bash
pnpm install
pnpm dev               # 以 debug 构建应用并打开
pnpm build:native      # release 构建 + ad-hoc 签名 → dist/ui-atlas.app
pnpm test:native       # 对 native/ 运行 swift test（AtlasCoreTests + AtlasAppTests）
pnpm check             # Vitest（tests/）：MCP 工具、MCP server、对话 harness
pnpm mcp               # 以 stdio 启动 ui-atlas MCP server（通常由 Agent 自动启动）
```

运行单个测试：

```bash
pnpm vitest run tests/control-tools.test.ts -t "<name>"
swift test --package-path native --filter AtlasCoreTests.<SuiteOrTest>
```

`pnpm test:native` 经由 `scripts/native-swift.mjs` 执行，它把 SwiftPM 的 scratch/cache 目录固定在 `/private/tmp/ui-atlas-native-*` 下（可用 `UI_ATLAS_SWIFT_SCRATCH` / `UI_ATLAS_SWIFT_MODULE_CACHE` 覆盖），并传入 `--disable-sandbox`；不要在同一个 scratch 目录上同时跑两个 Swift 构建。Node 测试会启动真实的本机 socket、HTTP 服务和子进程，因此需要回环网络——禁止监听 localhost 的沙箱会让它们误报失败。

设置 `UI_ATLAS_FRAME_LOG=1` 后，应用每秒打印一次 `[frame] hitches=N frames=M`，用于平移/缩放的性能调优。

## 架构

**App 是设计文档的唯一持有者**（ADR 0006）。`AtlasStore` 持有 `DesignEditor`（文档 + 撤销历史）；画布、图层面板、属性面板和控制通道的修改都经它进行，人工与 Agent 的修改共用一条撤销历史。启动时是空白文档，不启动任何 Node 进程；只有对话面板发送消息时才启动 harness。`native-build.mjs` 把仓库路径、Node 路径和 PATH 写入应用包的 `Contents/Resources/workspace.json`，供对话面板找到 `scripts/agent-chat.mjs`。

**原生 target**（`native/Package.swift`，Swift 5 语言模式）：
- `AtlasCore` —— 纯逻辑、不依赖 AppKit：`DesignDocument`（图层模型、`.uiatlas` 读写与版本校验）、`DesignJSON`（JSON 与节点互转、字段校验、部分字段补丁——文件读取、Agent 创建与修改共用这唯一一份校验）、`DesignLayout`（自动布局、文字自适应、分组收缩；文字测量由 App 注入）、`DesignEditor`（树操作与撤销历史，连续手势记为一步）、`DesignHitTest`（Figma 式点击选中规则）、`CanvasInteraction`（把指针事件 + `HitTarget` 转换为 `InteractionEffect` 的状态机：移动、缩放把手、框选、创建、平移）、几何与视口、吸附、视口动画、`ControlProtocol`。可测试的规则放在这里。
- `AtlasApp` —— SwiftUI 外壳（`AtlasApp` 的菜单、`WorkspaceView`、`LayersPanel`、`InspectorPanel`、`ChatPanel`）、`AtlasStore`，以及 AppKit 画布：`NativeCanvas`（NSViewRepresentable 桥接）→ `AtlasCanvasView`（处理输入，通过 `CanvasHost` 协议把编辑交给 store）、`DesignRenderer`（文档 → CALayer 树，按 id 增量更新；`snapshotPNG` 离屏截图）、`TextMetrics`/`TextLayer`（CoreText 测量与绘制共用同一排版）、`CanvasViewport`（平移移动 `world.bounds`；缩放以 GPU 变换渲染，稳定后再提交并更新文字/图片的 `contentsScale`）、`CanvasGrid`、`CanvasOverlay`（选框、把手、顶层画框名称、框选、参考线，从不接收输入）。

store 在每次文档变化时直接调用 `canvas.show(document)`（拖动时每帧都走这条路，不经 SwiftUI）；面板读取的 `@Published document` 在连续手势期间不更新，结束时一次更新。视口仍是画布持有实时值、只把稳定值回报给 store，store 用带 token 的 `ViewportRequest` 向下推送一次性视口变更。

**Agent 接入**（ADR 0003、0006）。`scripts/atlas-tools.mjs` 是唯一的工具实现，被 MCP server（`scripts/mcp-server.mjs`，`.mcp.json` 注册为 `ui-atlas`）和 App 对话面板的 Agent harness（`scripts/agent-chat.mjs`，JSON 行协议，模型适配在 `agent-providers.mjs`）共用。所有工具经 `scripts/control-client.mjs` 转发给 App 的控制通道（`~/Library/Application Support/ui-atlas/control.sock`，可用 `UI_ATLAS_CONTROL_SOCKET` 覆盖）；Node 端只把 `image.path` 读成 base64、把相对文件路径按仓库目录解析，不做字段校验。协议在 `AtlasCore/ControlProtocol.swift`，监听在 `AtlasApp/ControlServer.swift`，命令分发在 `ControlCommands.swift`。对话面板的 API key 存在钥匙串，只经环境变量 `UI_ATLAS_API_KEY` 传给 harness。

## 约定

- 远端：`origin` → https://github.com/Bald-M/ui-atlas（默认分支 `main`）。未配置 CI 或部署，本地检查即门禁。在任务分支上交付，推送后向 `main` 发起 PR。
- 任务直接用 `gh issue` 在 GitHub Issues 创建和跟踪，不在本地维护任务记录；`.scratch/<feature>/` 只用于起草较长的规格或计划。
- 新术语记入 `GLOSSARY.md`，架构决策记入 `docs/adr/`。ADR 0002 已彻底移除浏览器外壳，ADR 0006 已移除网页作品链路——不要重新引入 `apps/atlas`、`catalog.json`、`examples/`、预览启动器或 WKWebView 画框。
- 界面改动需在真实应用中按浅色和深色两种外观检查；证据截图放在 `docs/evidence/`。
