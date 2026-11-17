# ui-atlas

English | [简体中文](README.zh-CN.md)

A native AI design tool that runs on your own Mac. The canvas shows a design document made of layers, with Figma-style interaction; you and AI agents edit the same document, every change shows up on the canvas immediately, and designs are saved as ui-atlas's own project files (`.uiatlas`).

The App is a **native SwiftUI + AppKit macOS App**. The canvas renders layers directly with Core Animation and does not depend on a web server. Node is used only for the MCP server and the Agent harness behind the in-app chat panel.

The App UI is currently Chinese-only. In this README, menus, panels, and buttons are described in English with the label shown in the App in parentheses the first time they appear, e.g. *Layers panel (图层)*. Terms follow the English names in [GLOSSARY.md](GLOSSARY.md).

![ui-atlas main window: layers panel on the left, canvas in the middle, properties panel on the right](docs/evidence/readme-main-light.jpg)

The current version is v0.0.1; see the [CHANGELOG](CHANGELOG.md) for changes.

## Install and build

Requires macOS 14+, Swift 6+ (the Xcode Command Line Tools are enough; full Xcode is not needed), Node.js **22.12+**, and pnpm **11.7.0**. The App is only built from source on your own machine; there is no prebuilt installer.

```bash
pnpm install
pnpm build:native        # Release 构建并 ad-hoc 签名，产出 dist/ui-atlas.app
open dist/ui-atlas.app
```

During development, use `pnpm dev` to build a Debug build and open the App. You can drag `dist/ui-atlas.app` into the Applications folder, but the chat panel and the MCP connector depend on the source directory used at build time, so keep this checkout.

## Getting started

When the App starts it first shows the launch window (启动窗口): create a new design document (New, 新建, ⌘N), open a project file (Open, 打开, ⌘O), continue a file from Recent (最近打开), or start from one of the App's built-in templates (模板). Once you are editing, use the toolbar's Frame (画框, F), Rectangle (矩形, R), Ellipse (椭圆, O), and Text (文字, T) tools to create layers on the canvas, edit them in the layers panel (图层) on the left and the properties panel (the Design (设计) tab of the inspector) on the right, or let an agent build the UI.

For canvas operations, panels, files, and keyboard shortcuts, see the [macOS guide (macOS 使用说明)](docs/macos.md).

Before contributing, read the [contributing guide](CONTRIBUTING.md).

## `.uiatlas` project files

Use Save (保存, ⌘S) and Save As (另存为…, ⇧⌘S) in the File menu (文件) to save a design as a `.uiatlas` project file, and Open (⌘O) or Open Recent (打开最近) to reopen it. The App exports the `.uiatlas` file type, so double-clicking in Finder, dragging onto the Dock icon, or Open With all open the file with ui-atlas; if there are unsaved changes, the App first asks whether to save them.

### Document format

A design document is a tree of layers. It supports frames, rectangles, ellipses, text, images, and groups, as well as fill, stroke, corner radius, opacity, show/hide, lock, and auto layout on frames. A project file is public JSON with a format version number:

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

Coordinates are relative to the parent layer; array order is stacking order, with later items on top. What is saved is the geometry after auto layout has been computed. For the full set of fields and validation rules, see the [design document spec](docs/superpowers/specs/2026-11-17-native-design-document-design.md) and [ADR 0006](docs/adr/0006-native-design-document.md). This release does not interoperate with Figma.

## Directory layout

```text
native/                    SwiftUI + AppKit 原生 App 与 Swift 测试
  Sources/AtlasCore/       文档模型、校验、自动布局、编辑历史、交互规则、控制协议（不依赖 AppKit）
  Sources/AtlasApp/        画布渲染、图层与属性面板、对话面板、控制通道
scripts/                   原生构建与测试、MCP server、Agent harness 与共用工具
tests/                     Node 测试（Vitest）
```

- `native/`: the native SwiftUI + AppKit App and the Swift tests.
  - `Sources/AtlasCore/`: document model, validation, auto layout, edit history, interaction rules, and the control protocol (no AppKit dependency).
  - `Sources/AtlasApp/`: canvas rendering, layers and properties panels, chat panel, and control channel.
- `scripts/`: native build and test, the MCP server, the Agent harness, and shared tools.
- `tests/`: Node tests (Vitest).

## AI agent integration

ui-atlas provides a set of design tools for AI agents (`scripts/atlas-tools.mjs`), shared by the MCP server and the in-app chat panel; see [ADR 0003](docs/adr/0003-agent-mcp.md) and [ADR 0006](docs/adr/0006-native-design-document.md) for the design. Every tool is forwarded to the running App, which is the sole owner of the design document; when the App is not running, tools return "ui-atlas 未运行" (ui-atlas is not running).

- **Read**: `design_get_state` (file, selection, whether undo is available, and a summary of top-level layers), `design_get_document` (the full layer tree), `design_get_node`.
- **Edit**: `design_create_node` (use `children` to create a whole subtree at once), `design_update_node` (partial field patch; nested objects are merged field by field), `design_delete_nodes`, `design_move_node`, `design_select`, `design_undo`, `design_redo`. Each call is one undo step and the canvas updates immediately; field errors return an explanation in Chinese and leave the document unchanged. For images you can pass `image.path` (a local PNG/JPEG path), which the tool reads into base64.
- **File**: `design_new_document`, `design_open_document`, `design_save_document`. When there are unsaved changes, creating or opening a document is rejected unless you pass `discard: true`.
- **Viewport and checking**: `canvas_focus_node`, `canvas_fit_all`, `canvas_zoom`, and `design_snapshot`, which returns a PNG of the actual rendering.

The tools communicate through the App's **control channel**: `~/Library/Application Support/ui-atlas/control.sock` (override with `UI_ATLAS_CONTROL_SOCKET`). It is open only to the current user and does not listen on any network address.

### MCP connector

The App menu item *ui-atlas → MCP Connector… (MCP 连接器…)* lists the connection status of Claude Code and Codex. When one is not connected, click Connect (连接) and the App calls the matching CLI to register this checkout's MCP server in that agent's user-level configuration (`claude mcp add --scope user` / `codex mcp add`); when it is connected, click Disconnect (断开连接) to remove the registration. If the matching CLI is not installed on this Mac, it is shown as unavailable. Once connected, the server takes effect in newly opened agent sessions; the manual setup below still works.

### Claude Code

The `.mcp.json` at the repository root already registers `ui-atlas`. Start `claude` from the repository root; the first time, it asks whether to enable the project MCP server, and after you agree you can see it in `/mcp`.

### Codex

Add the following to `~/.codex/config.toml` (replace the path with the absolute path of this checkout):

```toml
[mcp_servers.ui-atlas]
command = "node"
args = ["/path/to/ui-atlas/scripts/mcp-server.mjs"]
```

You can also run `codex mcp add ui-atlas -- node /path/to/ui-atlas/scripts/mcp-server.mjs`. By default the MCP server uses the repository directory that contains the script; append `--root <directory>` to point it at another checkout.

By default Codex asks for approval before every MCP tool call; in unattended modes such as `codex exec` the call is rejected outright. To skip approval, add the line `default_tools_approval_mode = "approve"` to the configuration above (write tools modify the design document directly, so enable it only when you need it).

### In-app chat panel

Switch the inspector on the right to the Chat (对话) tab (⇧⌘A) to have AI build or modify the UI directly; every tool call and its result is shown in the panel and can be expanded for details. You can stop a reply while it is in progress, and no further tool calls run after stopping.

In the panel's Model Settings (模型设置), choose a model provider (模型提供方) and enter an API key:

| Model provider | API | Default API URL | Default model |
| --- | --- | --- | --- |
| DeepSeek | OpenAI-compatible | `https://api.deepseek.com` | `deepseek-chat` |
| Anthropic Claude | Messages API | `https://api.anthropic.com` | `claude-sonnet-5-5` |
| OpenAI | Responses API | `https://api.openai.com/v1` | `gpt-5-codex` |

When Model (模型) and API URL (接口地址) are left empty, the defaults in the table above are used. OpenAI's Codex models support only the Responses API; for other services compatible with OpenAI Chat Completions, choose DeepSeek and enter your own API URL and model name. The API key is stored only in the local Keychain (service name `ui-atlas.agent`) and is passed by the App through an environment variable when it starts the chat program (the Agent harness, `scripts/agent-chat.mjs`); it is never written to the repository, project files, preferences, or logs.

## Verification

```bash
pnpm test:native   # Swift 测试：AtlasCoreTests 与 AtlasAppTests
pnpm check   # Vitest：MCP 工具、MCP server 与对话 harness
```

`pnpm test:native` runs the Swift tests (AtlasCoreTests and AtlasAppTests); `pnpm check` runs Vitest (MCP tools, the MCP server, and the chat harness). The Node tests start child processes and local sockets, so they need loopback networking; a sandbox that forbids listening on local ports makes them fail spuriously.

The source is hosted on [GitHub](https://github.com/Bald-M/ui-atlas) and released under the Apache-2.0 license. The App is built and run only on your own machine; there is no CI, cloud sync, or production deployment.
