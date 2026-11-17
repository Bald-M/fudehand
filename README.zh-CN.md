# ui-atlas

[English](README.md) | 简体中文

一个放在本机的原生 AI 设计工具。画布上是由图层组成的设计文档，交互参照 Figma；你和 AI Agent 编辑同一份文档，每次修改都立即显示在画布上，设计稿保存为 ui-atlas 自己的工程文件（`.uiatlas`）。

App 是 **SwiftUI + AppKit 原生 macOS App**，画布用 Core Animation 直接渲染图层，不依赖网页服务。Node 只用于 MCP server 和 App 内对话面板的 Agent harness。

![ui-atlas 主界面：左侧图层面板、中间画布、右侧属性面板](docs/evidence/readme-main-light.jpg)

当前版本 v0.0.2，变更记录见 [CHANGELOG](CHANGELOG.md)。

## 安装与构建

需要 macOS 14+、Swift 6+（Xcode Command Line Tools 即可，不需要完整 Xcode）、Node.js **22.12+** 和 pnpm **11.7.0**。App 只从源码在本机构建，没有预编译安装包。

```bash
pnpm install
pnpm build:native        # Release 构建并 ad-hoc 签名，产出 dist/ui-atlas.app
open dist/ui-atlas.app
```

开发时用 `pnpm dev` 以 Debug 构建并打开 App。`dist/ui-atlas.app` 可以拖进“应用程序”文件夹使用，但对话面板和 MCP 连接器依赖构建时的源码目录，请保留本检出目录。

## 开始使用

App 启动时先显示启动窗口：新建设计文档（⌘N）、打开工程文件（⌘O）、从“最近打开”继续上次的文件，或从 App 自带模板开始。进入编辑后，用工具栏的画框（F）、矩形（R）、椭圆（O）、文字（T）工具在画布上创建图层，在左侧图层面板和右侧属性面板中编辑，或让 Agent 搭建界面。

界面语言默认是美式英语，可在应用菜单的 Language（语言）子菜单中切换为英式英语、简体中文或繁体中文，选择会保留到下次启动。

画布操作、面板、文件与快捷键见 [macOS 使用说明](docs/macos.md)。

参与开发前请先阅读[贡献指南](CONTRIBUTING.md)（英文）。

## `.uiatlas` 工程文件

设计稿用文件菜单的保存（⌘S）、另存为（⇧⌘S）存为 `.uiatlas` 工程文件，打开（⌘O）或“打开最近”重新打开。App 导出了 `.uiatlas` 文件类型，Finder 双击、拖到 Dock 图标或“打开方式”都会用 ui-atlas 打开；有未保存修改时会先询问是否保存。

### 文档格式

设计文档是一棵图层树，支持画框、矩形、椭圆、文字、图片、分组，以及填充、描边、圆角、透明度、显示/隐藏、锁定和画框的自动布局。工程文件是带格式版本号的公开 JSON：

```json
{
  "format": "ui-atlas.design",
  "version": 1,
  "nodes": [
    { "id": "home", "type": "frame", "name": "首页", "x": 0, "y": 0, "width": 390, "height": 844, "fill": "#FFFFFF",
      "layout": { "direction": "vertical", "spacing": 12, "padding": { "top": 16, "right": 16, "bottom": 16, "left": 16 },
                  "align": "start", "crossAlign": "stretch" },
      "children": [
        { "id": "title", "type": "text", "name": "标题", "x": 16, "y": 16, "width": 358, "height": 30,
          "text": { "content": "今日计划", "fontSize": 24, "fontWeight": 700, "color": "#111111", "align": "left", "autoResize": "height" } }
      ] }
  ]
}
```

坐标相对父图层；数组顺序即层叠顺序，后者在上。保存的是自动布局计算后的几何。完整字段与校验规则见 [设计文档](docs/superpowers/specs/2026-11-17-native-design-document-design.md) 和 [ADR 0006](docs/adr/0006-native-design-document.md)。本期不与 Figma 互通。

## 目录

```text
native/                    SwiftUI + AppKit 原生 App 与 Swift 测试
  Sources/AtlasCore/       文档模型、校验、自动布局、编辑历史、交互规则、控制协议（不依赖 AppKit）
  Sources/AtlasApp/        画布渲染、图层与属性面板、对话面板、控制通道
scripts/                   原生构建与测试、MCP server、Agent harness 与共用工具
tests/                     Node 测试（Vitest）
```

## AI Agent 接入

ui-atlas 为 AI Agent 提供一组设计工具（`scripts/atlas-tools.mjs`），MCP server 和 App 内对话面板共用，设计见 [ADR 0003](docs/adr/0003-agent-mcp.md) 与 [ADR 0006](docs/adr/0006-native-design-document.md)。所有工具都转发给正在运行的 App，App 是设计文档的唯一持有者；App 未运行时返回“ui-atlas 未运行”。

- **读取**：`design_get_state`（文件、选择、可否撤销、顶层图层摘要）、`design_get_document`（完整图层树）、`design_get_node`。
- **编辑**：`design_create_node`（可用 `children` 一次创建整棵子树）、`design_update_node`（部分字段补丁，嵌套对象逐字段合并）、`design_delete_nodes`、`design_move_node`、`design_select`、`design_undo`、`design_redo`。每次调用是一步撤销，画布立即更新；字段错误返回中文说明且文档不变。图片可以给 `image.path`（本机 PNG/JPEG 路径），由工具读成 base64。单个请求上限 32 MB，约可容纳 24 MB 的图片文件。
- **文件**：`design_new_document`、`design_open_document`、`design_save_document`。有未保存修改时新建或打开会被拒绝，除非传 `discard: true`。
- **视口与核对**：`canvas_focus_node`、`canvas_fit_all`、`canvas_zoom`，以及按实际渲染返回 PNG 的 `design_snapshot`。

工具经 App 的**控制通道**通信：`~/Library/Application Support/ui-atlas/control.sock`（可用 `UI_ATLAS_CONTROL_SOCKET` 覆盖），只对当前用户开放，不监听网络地址。

### MCP 连接器

App 的应用菜单“ui-atlas → MCP 连接器…”列出 Claude Code 和 Codex 的连接状态：未连接时点“连接”，App 会调用对应 CLI 把本检出目录的 MCP server 注册到该 Agent 的用户级配置（`claude mcp add --scope user` / `codex mcp add`）；已连接时点“断开连接”移除注册。本机没装对应 CLI 时显示“不可用”。连接后在新开的 Agent 会话中生效，下面的手动方式仍然可用。

### Claude Code

仓库根目录的 `.mcp.json` 已注册 `ui-atlas`。在仓库根目录启动 `claude`，首次会询问是否启用项目 MCP server，同意后即可在 `/mcp` 中看到它。

### Codex

在 `~/.codex/config.toml` 中加入（路径换成本检出目录的绝对路径）：

```toml
[mcp_servers.ui-atlas]
command = "node"
args = ["/path/to/ui-atlas/scripts/mcp-server.mjs"]
```

也可以执行 `codex mcp add ui-atlas -- node /path/to/ui-atlas/scripts/mcp-server.mjs`。MCP server 默认使用脚本所在的仓库目录，需要指向其他检出目录时追加 `--root <目录>`。

Codex 默认在每次调用 MCP 工具前请求批准；`codex exec` 等无人值守模式下会直接拒绝调用。需要免批准时，在上面的配置中加一行 `default_tools_approval_mode = "approve"`（写工具会直接修改设计文档，按需开启）。

### App 内对话面板

在右侧检查器切换到“对话”页（⇧⌘A），可以直接让 AI 搭建或修改界面；每次工具调用和结果都显示在面板中，可展开查看详情。回复过程中可以停止，停止后不再执行后续工具调用。

在面板的“模型设置”中选择模型提供方并填写 API key：

| 模型提供方 | 接口 | 默认接口地址 | 默认模型 |
| --- | --- | --- | --- |
| DeepSeek | OpenAI 兼容 | `https://api.deepseek.com` | `deepseek-chat` |
| Anthropic Claude | Messages API | `https://api.anthropic.com` | `claude-sonnet-5-5` |
| OpenAI | Responses API | `https://api.openai.com/v1` | `gpt-5.3-codex` |

“模型”和“接口地址”留空时使用上表默认值；OpenAI 的 Codex 系列模型只支持 Responses API；其他兼容 OpenAI Chat Completions 的服务可以选 DeepSeek 并填写自己的接口地址和模型名。API key 只保存在本机钥匙串（服务名 `ui-atlas.agent`），由 App 在启动对话程序（Agent harness，`scripts/agent-chat.mjs`）时经环境变量传入，不写入仓库、工程文件、偏好设置或日志。

## 验证

```bash
pnpm test:native   # Swift 测试：AtlasCoreTests 与 AtlasAppTests
pnpm check   # Vitest：MCP 工具、MCP server 与对话 harness
```

Node 测试会启动子进程和本机 socket，需要回环网络；禁止监听本机端口的沙箱会让它们误报失败。

## 发布

发布前先统一版本号，再手动在 [CHANGELOG](CHANGELOG.md) 归档本版本，并更新本文开头的“当前版本”：

```bash
pnpm version:set 0.0.2   # 改写 package.json 与 Info.plist 的版本号，构建号（CFBundleVersion）加 1
pnpm version:check       # 检查各处版本号一致，不一致时列出差异并以非 0 退出
```

MCP server 运行时读取 `package.json` 的版本号，App“关于”窗口的版本来自 `native/Resources/Info.plist`。

源码托管在 [GitHub](https://github.com/Bald-M/ui-atlas)，以 Apache-2.0 许可发布。App 仅在本机构建和运行，不配置 CI、云同步或生产部署。
