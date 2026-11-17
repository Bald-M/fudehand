# Changelog

本项目所有值得关注的变更都会记录在此。

本文档格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[Semantic Versioning](https://semver.org/lang/zh-CN/)。后续 PR 应先将值得关注的变更记录在
`Unreleased`，发布时再归档到对应版本。

## [Unreleased]

### Summary

尚未发布正式版本（`package.json` 为 `0.1.0`）。本节汇总首个版本的内容：原生 macOS 画布提供 Figma 式交互，作品只在 App 画框中按需启动和查看；Agent 可经 MCP server 或 App 内对话面板读写作品、控制画布并读取画框页面。#46 起改为原生 AI 设计工具：画布显示由图层组成的设计文档，人和 Agent 编辑同一份文档并保存为 `.uiatlas` 工程文件，网页作品链路随之移除。

### Added

- 原生 macOS 应用（SwiftUI + AppKit）：在可平移、可缩放的画布上以固定 CSS 视口的画框显示 Vue/React/HTML 作品，界面与示例为简体中文（ADR 0001）。
- Figma 式画布交互：画框选择、框选、拖动吸附与参考线、视口动画、按手势锁定的滚动路由（#1）。
- MCP server（`pnpm mcp`，`.mcp.json` 注册为 `ui-atlas`）：只读作品工具（#12）、画框与作品的写入工具（#13）、画布控制与画框截图工具（#17），以及画框控制台、页面读取与基础交互工具（#37）。
- App 本地控制通道，供 Agent 工具操作画布（#16）。
- App 内对话面板与 Agent harness（#26）；模型设置自动获取模型列表，API key 遮蔽显示并只存钥匙串（#34）。
- 作品服务按需启动：选中作品时才拉起其开发服务，单个作品失败可单独重试（#39，ADR 0004）。
- 侧栏显示作品缩略图和最近修改时间，可按目录顺序或最近修改排序，并可右键置顶（#43）。
- 按住空格时光标立即变为抓手（#31）。
- 原生设计文档与 Figma 式工作流：画框、矩形、椭圆、文字、图片、分组与自动布局，Core Animation 直接渲染；画布选择、移动、缩放把手与创建工具，图层面板与属性面板；`.uiatlas` 工程文件（带格式版本号的 JSON）；人工与 Agent 共用的撤销历史（#46，ADR 0006）。
- Agent 设计工具 `design_*`、`canvas_*` 与 `design_snapshot`，经控制通道编辑设计文档并截图核对（#46）。
- 启动窗口：新建设计文档、最近打开（最多 10 条，文件菜单“打开最近”共用）与 App 自带模板（#54）。

### Changed

- 滚轮和触控板滚动始终平移画布，⌥ + 滚动查看画框内的长页面（#42）。
- ⌘ / ⌃ + 滚轮按物理方向缩放，不受系统自然滚动设置影响（#38、#41）。
- 作品只在 App 画框中打开：移除“在浏览器打开”，作品服务拒绝不带预览令牌的请求（#44，ADR 0005）。
- 画框内网页隐藏滚动条（#28）。
- 产品名统一为 ui-atlas，不再使用中文名“界面图鉴”（#45）。
- 任务记录改用 GitHub Issues，Issue 优先级自行判定（#8、#10、#11）。

### Removed

- 网页作品链路：WKWebView 画框、预览启动器与作品服务、`catalog.json`、`examples/`，以及作品与画框相关的 MCP 工具和侧栏缩略图；ADR 0004、0005 被 ADR 0006 取代（#46）。
- 浏览器兼容的 Web 外壳（`apps/atlas`、`dev:web`、4400 端口与 iframe 桥接），见 ADR 0002。
- 画布底栏的端类型按钮（#40）。

### Fixed

- 打开面板无法选择 `.uiatlas` 工程文件：App 导出工程文件类型并登记为编辑器，Finder 双击也能打开（#50）。
- 关闭画框 WebKit 自动内容内边距，平移时网页不再伸缩（#25）。

### Upgrade Notes

- #46 起不再读取 `catalog.json` 和网页作品；Agent 配置中的作品与画框工具改用 `design_*` 设计工具（见 README）。`pnpm check` 只运行 Vitest。
- 改名后应用包为 `dist/ui-atlas.app`，控制通道位于 `~/Library/Application Support/ui-atlas/control.sock`，钥匙串服务名为 `ui-atlas.agent`。改名前保存在钥匙串的对话面板 API key 需要重新填写（#45）。
- Codex 调用 MCP 工具的批准设置见 [README](README.md)（#33）；MCP、控制通道与对话面板设计见 [ADR 0003](docs/adr/0003-agent-mcp.md)（#27）。
