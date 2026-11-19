# Fudehand

A native AI design tool: people and agents edit the same design document on the same canvas.

## Terms

The App UI comes in US English (the default), British English, Simplified Chinese, and Traditional Chinese. Each term leads with its English name, the same in both English variants, followed in parentheses by the Simplified and Traditional Chinese names the App uses. The App's string tables (`native/Sources/FudehandCore/Resources/`) must use these names.

**Design document (设计文档 / 設計文件)**: A tree of layers; everything shown on the canvas. The App is its only owner; changes from people and agents both apply to it and share one undo history.
_Avoid_: work (作品), project directory (项目目录) (these refer to the removed web-project pipeline)

**Project file (工程文件 / 專案檔)**: The file a design document is saved as, with the extension `.fudehand`; its content is public JSON with a format name (`fudehand.design`) and a format version.

**Layer (图层 / 圖層)**: A node in the design document, of type frame, rectangle, ellipse, text, image, or group. Coordinates are relative to the parent layer. An image layer holds PNG, JPEG, or SVG data; SVG is kept as source and drawn sharp at any zoom.
_Avoid_: element (元素), component (组件) (components mean something else and are out of scope for now)

**Frame (画框 / 畫框)**: A layer that can contain child layers, with fill, corner radius, clip content, and auto layout. A top-level frame usually represents a screen, and the canvas shows a name label above it.
_Avoid_: device simulator (设备模拟器), web frame (网页框)

**Group (分组 / 群組)**: A layer used to organize child layers. It cannot use auto layout or be resized with handles, and its size always equals the union of its child layers. Inside an auto layout frame a group is placed like any other child layer but ignores fill container (fill) and cross-axis stretch: it keeps the size of its child layers and takes no share of the remaining space.

**Auto layout (自动布局 / 自動佈局)**: A frame arranges its child layers automatically by direction, spacing, padding, and alignment; a child layer's sizing mode can be fixed, hug contents (hug), or fill container (fill).

**Prototype (原型 / 原型)**: A design document played as clickable screens in the prototype window: its top-level frames are the screens, and layers with an interaction move between them.

**Interaction (交互 / 互動)**: A layer's click behavior in a prototype: *Navigate to* (跳转到 / 跳至) a top-level frame, or *Back* (返回 / 返回) to the frame shown before. Saved on the layer in the project file.
_Avoid_: link, hotspot, action (an interaction's *Action* is only its navigate-or-back choice)

**Transition (转场 / 轉場)**: How the prototype window moves from one frame to the next: None, Dissolve (淡入淡出), Push Left/Right/Up/Down (向左/右/上/下推入), or Bottom Sheet (底部弹出 / 底部彈出), with a duration and an easing. Back plays it in reverse.
_Avoid_: animation (reserved for a layer's own animation)

**Animation (动画 / 動畫)**: A layer's motion during prototype playback, started when its frame appears: an *Entrance* (入场 / 進場) — Fade In (淡入), Slide In (滑入), Scale In (缩放进入 / 縮放進入) — or a *Loop* (循环 / 循環) — Spin (旋转 / 旋轉), Pulse (脉冲 / 脈衝), Shimmer (流光 / 流光). Appearance only: it never changes the design document, and the canvas and snapshots show the layer still.
_Avoid_: effect, motion, transition (the move between frames)

**Text sequence (文字序列 / 文字序列)**: A text layer's list of texts shown one after another at a fixed interval during playback, looping or stopping on the last one — the look of a countdown. It triggers nothing; the layer's own text is what editing shows.
_Avoid_: timer, countdown (it does not count real time)

**Prototype window (原型窗口 / 原型視窗)**: The separate window opened by *Play Prototype (播放原型)* that plays the prototype at the frames' actual size; clicks there trigger interactions instead of selecting layers.
_Avoid_: preview mode, present mode

**Canvas (画布 / 畫布)**: The pannable, zoomable workspace that displays the design document.

**Layers panel (图层面板 / 圖層面板)**: The layer tree in the left sidebar, used to select, rename, show/hide, and lock layers.

**Properties panel (属性面板 / 屬性面板)**: The Design (设计) tab of the right inspector, which edits the selected layer's position, size, fill, stroke, text, and auto layout.

**Font library (字体库 / 字體庫)**: The directory `~/Library/Application Support/fudehand/Fonts` holding font files imported with *Import Font…* or `design_import_font`. Its fonts are registered for the App only, not installed on the system, and not stored in project files: a project file opened on a Mac without the font falls back to the system font.

**MCP server**: A local tool process (`scripts/mcp-server.mjs`) that external AI agents (Claude Code, Codex, DeepSeek Harness, and others) start on demand; it forwards design tools to the running App.

**Agent parity**: The rule that every App feature a person can use, settings included, is also an Agent tool ([ADR 0007](docs/adr/0007-agent-parity.md), `docs/agent-tools.md`).

**Launch window (启动窗口 / 啟動視窗)**: The window shown when the App starts, with three areas: New, Recent, and Templates. It closes once editing begins and can be reopened from *Window → Launch Window (窗口 › 启动窗口)*.
_Avoid_: welcome page (欢迎页), home page (首页)

**Template (模板 / 範本)**: A `.fudehand` design bundled with the App (`native/Resources/Templates/`), used in the launch window to create a new untitled design document; the new document is not linked to the template file, so saving never overwrites the template.
_Avoid_: example (示例), work template (作品模板) (these refer to the removed web-project pipeline)

**MCP connector (MCP 连接器 / MCP 連接器)**: The window opened from the app menu's *MCP Connectors… (MCP 连接器…)*. It detects whether the MCP server is registered in the user-level configuration of Claude Code, Codex, and DeepSeek Harness, and connects or disconnects it with one click (through the CLI for Claude Code and Codex; for DeepSeek Harness, which has no such command, by editing a marked block in its home patch file `~/.dsh/cordis.patch.yml`).
_Avoid_: plugin (插件), integration (集成)

**Control channel (控制通道 / 控制通道)**: A local Unix socket, open only to the current user while the App is running, through which external processes read and edit the design document, control the viewport, and take screenshots.
_Avoid_: control port (控制端口), API service (API 服务)

**Chat panel (对话面板 / 對話面板)**: The Chat (对话) tab of the right inspector, where AI reads and edits the design document with the same tools as the MCP server.

**Conversation (会话 / 對話)**: One exchange with the Agent in the chat panel, from its first message on. A conversation belongs to one design document's project file: opening the document restores its open conversation tabs, and the panel's *Conversation history* menu lists that document's conversations. Conversations are saved on this Mac, not in the project file.
_Avoid_: session (the App's `ChatSession` is the object that owns the conversations, not a term in the UI), thread

**Conversation tab (会话标签 / 對話標籤)**: A tab in the chat panel's header for one open conversation. Each has its own messages, model, and Agent harness; closing a tab stops its reply and keeps the conversation in the history.

**Context tag (上下文标签 / 上下文標籤)**: A removable tag above the chat input for a layer selected on the canvas; the layers still tagged when a message is sent are passed to the Agent with it.

**Question card (问题卡片 / 問題卡片)**: A card in the chat panel's transcript for a question the Agent paused its reply to ask, with up to four options (its recommendation first), a field for another answer, and *Skip, let AI decide*. Once answered it folds down to the question and the answer. The question is a tool of the Agent harness only; external agents on the MCP server do not have it.

**Next-message prediction (下一条消息预测 / 下一則訊息預測)**: The message the Agent harness predicts the user will send next, shown as the placeholder of the empty chat input after a reply ends; Tab puts it in the input. It is not part of the conversation.
_Avoid_: autocomplete, completion (nothing is completed while typing), suggestion chips

**Slash command (快捷指令 / 快捷指令)**: A command typed in the chat input, starting with `/` and chosen from the command menu: `/plan`, `/goal`, `/new`, `/clear`, `/compact`, `/model`. It acts on the chat panel and is never sent to the model.

**Plan mode (计划模式 / 計畫模式)**: A conversation mode, entered with `/plan`, in which the Agent can only read the design document and replies with a plan; the plan is carried out after the user confirms it with *Run Plan*.

**Goal mode (目标模式 / 目標模式)**: A conversation mode, entered with `/goal`, in which the next message is a goal the Agent keeps working on until it reports it done or the reply is stopped.

**Context ring (上下文圆环 / 上下文圓環)**: The ring in the chat input showing how much of the model's context window the conversation takes up.

**Compact (压缩 / 壓縮)**: Replacing the earlier messages the model sees with a summary of them, with the `/compact` slash command. The conversation's messages stay in the chat panel.
_Avoid_: compress, summarize (the summary is what compacting produces)

**Agent harness**: The Node child process behind the chat panel (`scripts/agent-chat.mjs`) that runs the conversation loop, calls the model API, and executes tools; it starts only when a message is sent.

**Model provider (模型提供方 / 模型提供者)**: The model API sources available in the chat panel: DeepSeek, Claude, and ChatGPT. DeepSeek uses an OpenAI-compatible API, Claude uses the Anthropic Messages API, and ChatGPT uses OpenAI's Responses API and needs an OpenAI API key.

**UI language (界面语言 / 介面語言)**: The language of the App's own copy, chosen in the app menu's *Language* submenu and remembered across launches. It does not follow the system language and never changes the content of a design document; a new layer's default name is written once, in the UI language at that moment.
