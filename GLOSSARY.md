# ui-atlas

A native AI design tool: people and agents edit the same design document on the same canvas.

## Terms

The App UI comes in US English (the default), British English, Simplified Chinese, and Traditional Chinese. Each term leads with its English name, the same in both English variants, followed in parentheses by the Simplified and Traditional Chinese names the App uses. The App's string tables (`native/Sources/AtlasCore/Resources/`) must use these names.

**Design document (设计文档 / 設計文件)**: A tree of layers; everything shown on the canvas. The App is its only owner; changes from people and agents both apply to it and share one undo history.
_Avoid_: work (作品), project directory (项目目录) (these refer to the removed web-project pipeline)

**Project file (工程文件 / 專案檔)**: The file a design document is saved as, with the extension `.uiatlas`; its content is public JSON with a format name (`ui-atlas.design`) and a format version.

**Layer (图层 / 圖層)**: A node in the design document, of type frame, rectangle, ellipse, text, image, or group. Coordinates are relative to the parent layer.
_Avoid_: element (元素), component (组件) (components mean something else and are out of scope for now)

**Frame (画框 / 畫框)**: A layer that can contain child layers, with fill, corner radius, clip content, and auto layout. A top-level frame usually represents a screen, and the canvas shows a name label above it.
_Avoid_: device simulator (设备模拟器), web frame (网页框)

**Group (分组 / 群組)**: A layer used to organize child layers. It cannot use auto layout or be resized with handles, and its size always equals the union of its child layers. Inside an auto layout frame a group is placed like any other child layer but ignores fill container (fill) and cross-axis stretch: it keeps the size of its child layers and takes no share of the remaining space.

**Auto layout (自动布局 / 自動佈局)**: A frame arranges its child layers automatically by direction, spacing, padding, and alignment; a child layer's sizing mode can be fixed, hug contents (hug), or fill container (fill).

**Canvas (画布 / 畫布)**: The pannable, zoomable workspace that displays the design document.

**Layers panel (图层面板 / 圖層面板)**: The layer tree in the left sidebar, used to select, rename, show/hide, and lock layers.

**Properties panel (属性面板 / 屬性面板)**: The Design (设计) tab of the right inspector, which edits the selected layer's position, size, fill, stroke, text, and auto layout.

**MCP server**: A local tool process (`scripts/mcp-server.mjs`) that external AI agents (Claude Code, Codex, and others) start on demand; it forwards design tools to the running App.

**Launch window (启动窗口 / 啟動視窗)**: The window shown when the App starts, with three areas: New, Recent, and Templates. It closes once editing begins and can be reopened from *Window → Launch Window (窗口 › 启动窗口)*.
_Avoid_: welcome page (欢迎页), home page (首页)

**Template (模板 / 範本)**: A `.uiatlas` design bundled with the App (`native/Resources/Templates/`), used in the launch window to create a new untitled design document; the new document is not linked to the template file, so saving never overwrites the template.
_Avoid_: example (示例), work template (作品模板) (these refer to the removed web-project pipeline)

**MCP connector (MCP 连接器 / MCP 連接器)**: The window opened from the app menu's *MCP Connectors… (MCP 连接器…)*. It detects whether the MCP server is registered in the user-level configuration of Claude Code and Codex, and connects or disconnects it with one click through their CLIs.
_Avoid_: plugin (插件), integration (集成)

**Control channel (控制通道 / 控制通道)**: A local Unix socket, open only to the current user while the App is running, through which external processes read and edit the design document, control the viewport, and take screenshots.
_Avoid_: control port (控制端口), API service (API 服务)

**Chat panel (对话面板 / 對話面板)**: The Chat (对话) tab of the right inspector, where AI reads and edits the design document with the same tools as the MCP server.

**Conversation (会话 / 對話)**: One exchange with the Agent in the chat panel, from its first message on. Conversations are saved on this Mac and reopened from the panel's *Conversation history* menu; they are not part of the design document.
_Avoid_: session (the App's `ChatSession` is the object that owns the conversations, not a term in the UI), thread

**Context tag (上下文标签 / 上下文標籤)**: A removable tag above the chat input for a layer selected on the canvas; the layers still tagged when a message is sent are passed to the Agent with it.

**Agent harness**: The Node child process behind the chat panel (`scripts/agent-chat.mjs`) that runs the conversation loop, calls the model API, and executes tools; it starts only when a message is sent.

**Model provider (模型提供方 / 模型提供者)**: The model API sources available in the chat panel: DeepSeek, Claude, and ChatGPT. DeepSeek uses an OpenAI-compatible API, Claude uses the Anthropic Messages API, and ChatGPT uses OpenAI's Responses API and needs an OpenAI API key.

**UI language (界面语言 / 介面語言)**: The language of the App's own copy, chosen in the app menu's *Language* submenu and remembered across launches. It does not follow the system language and never changes the content of a design document; a new layer's default name is written once, in the UI language at that moment.
