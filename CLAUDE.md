# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在本仓库中工作提供指引。

界面图鉴（UI Atlas）是一个用于研究界面设计的本地 macOS 应用：SwiftUI + AppKit 外壳把 Vue/React/HTML 学习项目（“作品”）以固定尺寸的网页框（“画框”）显示在可平移、可缩放的“画布”上。文档、界面文案和错误信息均为中文，术语以 `GLOSSARY.md` 为准。探索代码前先读 `GLOSSARY.md` 和相关的 `docs/adr/`；画布交互行为以 `docs/macos.md` 为权威规范。

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
pnpm build:native      # release 构建 + ad-hoc 签名 → dist/界面图鉴.app
pnpm test:native       # 对 native/ 运行 swift test（AtlasCoreTests + AtlasAppTests）
pnpm check             # 示例类型检查 + Vitest（tests/）+ 构建全部示例
```

运行单个测试：

```bash
pnpm vitest run tests/launcher.test.ts -t "<name>"
swift test --package-path native --filter AtlasCoreTests.<SuiteOrTest>
```

`pnpm test:native` 经由 `scripts/native-swift.mjs` 执行，它把 SwiftPM 的 scratch/cache 目录固定在 `/private/tmp/ui-atlas-native-*` 下（可用 `UI_ATLAS_SWIFT_SCRATCH` / `UI_ATLAS_SWIFT_MODULE_CACHE` 覆盖），并传入 `--disable-sandbox`；不要在同一个 scratch 目录上同时跑两个 Swift 构建。Node 测试会启动真实的 HTTP 服务和子进程，因此需要回环网络——禁止监听 localhost 的沙箱会让它们误报失败。

设置 `UI_ATLAS_FRAME_LOG=1` 后，应用每秒打印一次 `[frame] hitches=N frames=M`，用于平移/缩放的性能调优。

## 架构

**`catalog.json` 是唯一事实来源**，记录作品、画框、默认布局和预览启动配置（`preview.cwd/command/port/baseUrl`）。每个示例的 `vite.config.ts` 用 `readFileSync`（而不是 `import`，以免修改 catalog 时 Vite 重启所有服务）从中读取自己的端口和主机。catalog 校验实现了两份——`scripts/launcher.mjs`（Node）和 `native/Sources/AtlasCore/Catalog.swift`（Swift）——两边的测试套件都会运行 `tests/fixtures/catalog-conformance.json` 中的共享用例。任何规则变更都必须同时更新两边和该 fixture。

**进程模型。** Swift 应用（`PreviewSession`）启动 `node scripts/native-preview.mjs --root <repo>`，后者借助 `launcher.mjs` 启动每个 `enabled` 示例的开发服务，等到 HTTP 返回 2xx 后打印 `UI_ATLAS_READY`。应用持有该子进程的 stdin 管道；一旦 EOF（退出或崩溃），所有预览进程组都会被关闭。启动器从不杀掉占用端口的外部进程，也从不改用其他端口。`native-build.mjs` 会把仓库路径、Node 路径和 PATH 写入应用包的 `Contents/Resources/workspace.json`，所以构建出的应用依赖本检出目录及其 Node 安装。

**原生 target**（`native/Package.swift`，Swift 5 语言模式）：
- `AtlasCore` —— 纯逻辑、不依赖 AppKit：catalog 模型与校验、几何与视口计算、布局持久化、吸附、滚动路由、视口动画，以及 `CanvasInteraction`（把指针事件 + `HitTarget` 转换为 `InteractionEffect` 的状态机）。可测试的交互规则放在这里。
- `AtlasApp` —— SwiftUI 外壳（`AtlasApp`、`WorkspaceView`）、`AtlasStore`（应用状态，用 UserDefaults 持久化主题、工作区、每个作品的位置和视口），以及 AppKit 画布：`NativeCanvas`（NSViewRepresentable 桥接）→ `AtlasCanvasView`（处理输入、应用交互效果）、`CanvasViewport`（平移移动 `world.bounds`；缩放以 GPU 变换渲染，稳定后再提交）、`CanvasGrid`、`CanvasOverlay`（选区/框选/参考线，从不接收输入），以及 `PreviewFrameView`（每个画框一个 WKWebView，注入 Esc 脚本）。

画布持有实时视口和选区，只把稳定后的值回报给 `AtlasStore`；store 通过带 token 的请求（`ViewportRequest`、`positionsToken`、`reloadToken`）向下推送一次性变更——新 token 表示“应用一次”。画框整体做视觉缩放；每个 web view 保持其配置的 CSS 视口尺寸，因此响应式断点不会随缩放改变。

**示例**位于 `examples/*`（pnpm workspace）。应用直接从各自端口加载它们（不经代理）。没有后端，也没有静态站点打包产物。

## 约定

- 远端：`origin` → https://github.com/Bald-M/ui-atlas（默认分支 `main`）。未配置 CI 或部署，本地检查即门禁。在任务分支上交付，推送后向 `main` 发起 PR。
- 任务直接用 `gh issue` 在 GitHub Issues 创建和跟踪，不在本地维护任务记录；`.scratch/<feature>/` 只用于起草较长的规格或计划。
- 新术语记入 `GLOSSARY.md`，架构决策记入 `docs/adr/`。ADR 0002 已彻底移除浏览器外壳——不要重新引入 `apps/atlas`、`dev:web`、4400 外壳端口或 iframe 桥接。
- 界面改动需在真实应用中按浅色和深色两种外观检查；证据截图放在 `docs/evidence/`。
