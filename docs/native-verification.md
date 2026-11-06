# 原生迁移验证记录

环境：2026-11-06，Apple Silicon，macOS 15.2，Command Line Tools Swift 6.0.3，Node 22.22.2。未安装完整 Xcode；最低部署目标 macOS 14。

## 自动检查

- `pnpm check`：通过网页工作区类型检查、24 项 Vitest 测试和三个网页构建。其中包含 4 项新增原生服务入口真实进程测试。
- 默认执行沙箱禁止监听本机端口，首次 HTTP 测试因此失败；在允许 loopback 的执行环境重跑全部通过，未删除或跳过测试。
- `pnpm test:native`：6 项 Swift Testing 测试通过，覆盖有效配置、无效配置组、几何与布局恢复。
- `pnpm build:native`：Release 编译、链接和 App 打包成功；`codesign --verify --deep --strict dist/界面图鉴.app` 通过。

## 实际 App 验收

- 在实际 macOS App 中加载 Vue 三个尺寸画框和 React 案例，切换作品、聚焦移动端和搜索无结果状态正常。
- 系统浅色和深色外观均检查，证据见 `docs/evidence/native-light.png` 与 `native-dark.png`。
- 原有浏览器服务占端口时显示 EADDRINUSE 和重试；正常停止已确认属于本仓库的旧启动器后，App 重试成功。
- ⌘Q 退出后，4400、4401、4402 均没有监听服务；重开 App 后恢复最近作品、主题与视角，案例自动就绪。
- 实际网页弹窗验收发现原生 responder 链会提前处理 Escape，已修正为交互期间由网页桥决定退出，正在进行最终回归。

## 真实 WebKit 专项探针

临时 AppKit/WKWebView 探针直接采用原生画布的祖先视图坐标缩放方式。25% 和 50% 缩放加平移后，JavaScript `innerWidth/innerHeight` 和 WKWebView bounds 均保持 390×844。这验证网页响应式断点不随画布缩放改变。

另一临时 WKWebView 探针直接提取实际 Escape 注入脚本，依次发送普通 Escape、preventDefault、stopPropagation、打开 dialog 时 Escape、普通 Escape，原生桥只收到两次退出。探针加载内存 HTML，不将它描述为案例端到端验收。

## 交付范围

本仓库无远端；不创建 PR、CI 或部署。原有中文化改动保持未提交状态，本次迁移独立提交到 `codex/native-macos`。App 是依赖本机源码与 Node/pnpm 的本地构建，未做 Developer ID 签名或公证，不提供脱离源码的独立分发。

保留网页案例意味着仍存在 WebKit 进程和案例开发服务开销。本次没有基于可比工作负载做内存/CPU 对照，不承诺具体性能提升比例。
