# macOS 使用说明

界面图鉴现在默认运行 SwiftUI/AppKit 原生外壳。案例继续保留各自的 Vue、React 或 HTML 工具链，在系统 WKWebView 中展示。

## 启动与构建

需要 macOS 14+、Swift 6+、Node.js 22.12+、pnpm 11.7.0。安装 Xcode Command Line Tools 即可，不需要完整 Xcode，也没有第三方 Swift 包依赖。

```bash
pnpm install
pnpm dev                 # Debug 构建并打开 App
pnpm build:native        # Release 构建并进行本地 ad-hoc 签名
open dist/界面图鉴.app
```

App 启动后会读取仓库 `catalog.json`，只启动 `enabled: true` 的案例服务，不启动 4400 浏览器画布。关闭最后一个窗口或使用 ⌘Q 退出，会停止本次启动的案例。App 异常退出后，案例启动器也会通过所有权管道关闭来清理进程。

如果之前启动过浏览器版，请先在那个终端按 Ctrl+C；端口占用时，App 显示具体错误并提供重试。它不会终止占用端口的其他进程。

构建脚本把本机源码目录、Node 路径和启动时 PATH 写进 App 的 `Contents/Resources/workspace.json`。这是本地开发工具，需要保留源码、node_modules、Node 和 pnpm；复制 App 到另一台机器不能直接运行案例。移动目录后使用 App 的“打开项目目录…”选择仓库；更换 Node 版本或删除旧 Node 后重新构建 App。

SwiftPM 构建和模块缓存默认写到系统临时目录。`UI_ATLAS_SWIFT_SCRATCH` 可覆盖构建目录，`UI_ATLAS_SWIFT_MODULE_CACHE` 可覆盖模块缓存目录。不要同时在同一 scratch 目录运行两个 Swift 构建。

浏览器版仍可通过 `pnpm dev:web` 启动。

## 画布操作

- 在侧栏搜索或切换作品；底部显示介绍、作者与原作出处。
- 拖动空白或按空格拖动画布，也可以滚轮平移。
- ⌘ + 滚轮或触控板捏合，以指针位置缩放；工具栏提供放大、缩小和实际大小。
- ⌘0 适应全部；⌘1 恢复 100%；底部端类型按钮聚焦对应画框。
- 拖动画框标题调整位置；选择画框后方向键移动 10，Shift + 方向键移动 100；双击标题聚焦。
- 双击画框内容或使用标题栏的交互按钮，把输入交给网页。固定的“退出交互”按钮始终可用，也可使用 ⇧⌘Return。
- Esc 在网页未处理时退出交互；已有网页弹窗先处理 Esc。
- ⌘R 或工具栏重载当前作品的案例；标题栏按钮可用默认浏览器打开对应页面。
- 右上角菜单选择跟随系统、浅色或深色，或恢复默认布局。

画框尺寸仍然是 **CSS 视口**，不模拟 iOS 系统或设备原生能力。App 对画框整体做视觉缩放；网页仍按配置的原始宽高进行响应式排版。外部链接在浏览器中打开，画框主页面保持在该作品的本机服务内。

## 配置与保存

`catalog.json` 继续作为作品、案例命令和默认布局的唯一来源，案例接入方式沿用 README 的兼容版说明。修改目录后使用“重新读取目录并启动服务”。配置无效时给出错误，正在运行的有效项目保持可用。

原生 App 通过 UserDefaults 单独保存主题、最近目录、最近作品，以及按仓库目录和作品 ID 区分的位置、缩放与视角。它不读取浏览器 localStorage。配置的 `layoutVersion` 变化或保存数据损坏时回退到默认布局；新增画框使用配置位置；“恢复默认布局”只重置当前作品。

## 验证

```bash
pnpm test:native
pnpm check
pnpm build:native
codesign --verify --deep --strict dist/界面图鉴.app
```

Swift 测试覆盖目录校验、URL 解析、鼠标锚点缩放、拖动坐标、适应全部与布局恢复。Node 集成测试使用真实本机 HTTP 服务验证只启动案例、管道关闭清理、SIGTERM、异常退出以及保留外部占端口程序。

UI 证据及本次实际检查结果见 [原生迁移验证记录](native-verification.md)。
