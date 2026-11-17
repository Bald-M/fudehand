# 画布改为原生设计文档

2026-11-17（#46）。ui-atlas 从展示网页作品改为原生设计工具：画布上是 ui-atlas 自己的设计文档（图层树），由 App 用 Core Animation 直接渲染；人和 Agent 编辑同一份文档，Agent 经控制通道发送编辑命令，App 是文档的唯一持有者。设计稿保存为带版本号的公开 JSON 工程文件（`.uiatlas`）。

随之移除网页作品链路：`WKWebView` 画框、Node 预览启动器与案例服务、`catalog.json` 及其 Swift/Node 两份校验、`examples/` 中的网页作品。ADR 0004（案例服务按需启动）与 0005（作品只在 App 画框中打开）失效，只作历史记录保留。ADR 0003 的结构保留：MCP server 与对话面板 harness 仍共用 `scripts/atlas-tools.mjs`，但工具改为转发设计命令；文档字段的校验只在 Swift 一处。

## 否决的方案

- **继续用网页作品，Agent 改源码**：每个作品要有前端工程和常驻 Node/Vite/WebKit 进程，Agent 每次修改都经过编译与热更新，无法做到图层级的选择和属性编辑。
- **Node 端持有文档，App 只渲染**：文档会有两个持有者，人工编辑与 Agent 编辑需要同步与冲突处理。
- **Core Graphics 整体重绘或 SwiftUI 画布**：前者在 100 个以上图层时无法保证平移、缩放流畅；后者与现有 AppKit 画布的输入与视口实现割裂。
- **读写 Figma 格式**：本期非目标；自定义 JSON 便于 Agent 直接理解与版本管理。

## 影响

- App 启动不再启动任何 Node 进程；对话面板发送消息时才启动 harness，仍依赖本检出目录与 Node（`workspace.json`）。
- 之前基于网页作品的 Issue（#18、#20、#23、#36）需要重新评估。
- 渲染能力受 Core Animation 约束：本期不支持旋转、渐变、阴影、矢量路径。
