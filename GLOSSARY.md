# Fudehand

A native AI design tool: people and agents edit the same design document on the same canvas.

## Terms

The App UI comes in US English (the default), British English, Simplified Chinese, and Traditional Chinese. Each term leads with its English name, the same in both English variants, followed in parentheses by the Simplified and Traditional Chinese names the App uses. The App's string tables (`native/Sources/FudehandCore/Resources/`) must use these names.

**Design document (设计文档 / 設計文件)**: A tree of layers; everything shown on the canvas. The App is its only owner; changes from people and agents both apply to it and share one undo history.
_Avoid_: work (作品), project directory (项目目录) (these refer to the removed web-project pipeline)

**Project file (工程文件 / 專案檔)**: The file a design document is saved as, with the extension `.fudehand`; its content is public JSON with a format name (`fudehand.design`) and a format version.

**Layer (图层 / 圖層)**: A node in the design document, of type frame, rectangle, ellipse, text, image, icon, or group. Coordinates are relative to the parent layer. An image layer holds PNG, JPEG, or SVG data; SVG is kept as source and drawn sharp at any zoom.

**Icon layer (图标图层 / 圖示圖層)**: A layer that shows one single-color icon from an icon library. It stores only the icon name and color; its size is the layer's width and height, and it is drawn sharp at any zoom. An icon the library does not have draws as a placeholder.

**Icon library (图标库 / 圖示庫)**: A set of icons built into Fudehand, one per target platform: `sf` (SF Symbols, from the system), `material-outlined`, `material-rounded`, `material-sharp` (Material Symbols), `weui` (WeUI), and `lucide` (Lucide).

**Icon picker (图标选择面板 / 圖示選擇面板)**: The popover where a person switches between icon libraries, searches icons by keyword, and chooses one: from the bottom canvas toolbar to insert an icon layer, or from the properties panel to replace the icon of the selected icon layer.

**Icon name (图标名字 / 圖示名稱)**: How an icon layer names its icon: `<library>/<name>`, such as `sf/house.fill` or `material-rounded/home.fill`.
_Avoid_: element (元素), component (组件) (components mean something else and are out of scope for now)

**Frame (画框 / 畫框)**: A layer that can contain child layers, with fill, corner radius, clip content, auto layout, and layout guides. A top-level frame usually represents a screen, and the canvas shows a name label above it.
_Avoid_: device simulator (设备模拟器), web frame (网页框)

**Version snapshot (版本快照 / 版本快照)**: A read-only picture of a frame as it looked when it was saved, with the time and an optional note, kept as an image layer beside the frame so the old and new versions can be compared side by side or overlaid. It is saved in the project file and deleted like any other layer ([ADR 0010](docs/adr/0010-version-snapshots-are-image-layers.md)).
_Avoid_: version history, backup (a snapshot never restores the frame), snapshot alone (`design_snapshot` is the Agent's own PNG capture, which adds nothing to the document)

**Group (分组 / 群組)**: A layer used to organize child layers. It cannot use auto layout or be resized with handles, and its size always equals the union of its child layers. Inside an auto layout frame a group is placed like any other child layer but ignores fill container (fill) and cross-axis stretch: it keeps the size of its child layers and takes no share of the remaining space.

**Effect (效果 / 效果)**: A shadow or blur in a layer's effects list, drawn in list order: *Drop Shadow* (投影 / 投影) and *Inner Shadow* (内阴影 / 內陰影), with a color, an X/Y offset, a blur, and a spread; *Layer Blur* (图层模糊 / 圖層模糊), which blurs the layer with its children; and *Background Blur* (背景模糊 / 背景模糊), which blurs the layers under it in the same parent, seen through a see-through fill. *Noise* (噪点 / 雜訊) draws fixed grain over a frame, rectangle, or ellipse, above its fill and below its children, with a color, a grain size, a density, and a seed; the same seed always gives the same grains. *Texture* (纹理 / 紋理) repeats an image over a frame, rectangle, or ellipse in the same place, with a tile size, an opacity, and a blend mode (*Normal*, *Multiply*, *Screen*, *Overlay*, *Soft Light*). *Glass* (玻璃 / 玻璃) is frosted glass on a frame, rectangle, or ellipse: it blurs and saturates the layers under it in the same parent, then draws a *Tint* and a *Highlight* along the inside of its top edge; a layer has at most one, and never with a Background Blur. Each can be hidden without removing it. Every layer type but group has effects; noise, texture, and glass only frames, rectangles, and ellipses.
_Avoid_: filter, style (a reusable named effect is out of scope)

**Auto layout (自动布局 / 自動佈局)**: A frame arranges its child layers automatically by direction, spacing, padding, and alignment; a child layer's sizing mode can be fixed, hug contents (hug), or fill container (fill).

**Layout guide (布局辅助线 / 佈局輔助線)**: A grid, columns, or rows drawn over a frame on the editing canvas, with its own color, that can be shown or hidden. Layers moved or resized inside the frame snap to the edges of its visible columns and rows. Layout guides are saved with the frame but never appear in snapshots or prototype playback.
_Avoid_: snapping guide (吸附参考线, the red lines shown while dragging), ruler guide (标尺参考线, canvas-wide; out of scope)

**Prototype (原型 / 原型)**: A design document played as clickable screens in the prototype window: its top-level frames are the screens, and layers with an interaction move between them.

**Interaction (交互 / 互動)**: A layer's click behavior in a prototype: *Navigate to* (跳转到 / 跳至) a top-level frame, *Back* (返回 / 返回) to the frame shown before, *Open Overlay* (打开弹层 / 打開彈出層), *Close Overlay* (关闭弹层 / 關閉彈出層), or *Toggle Visibility* (切换显示 / 切換顯示). Saved on the layer in the project file.
_Avoid_: link, hotspot, action (an interaction's *Action* is only which of these it does)

**Overlay (弹层 / 彈出層)**: A top-level frame shown over the frame on show in the prototype window — a dialog, bottom panel, or menu — placed at the center, along the bottom, or below the layer that opened it, optionally over a background color that dims the frame below. While it is open only it takes input.
_Avoid_: modal, popup, popover

**Scrolling (滚动 / 捲動)**: A frame's setting (None, Vertical, Horizontal) that lets its overflowing content scroll in the prototype window. A direct child marked *Fix position when scrolling* (滚动时固定位置 / 捲動時固定位置) stays put above the scrolled content.

**State (状态 / 狀態)**: How a layer looks in the prototype window *while hovered* (悬停时 / 懸停時) and *while pressed* (按下时 / 按下時): a fill and an opacity that replace the layer's own, eased in and out.
_Avoid_: variant (components and variants are out of scope)

**Toggle Visibility (切换显示 / 切換顯示)**: The interaction that shows the hidden and hides the shown among chosen layers, for tabs, switches, checkboxes, and expand/collapse. The change lasts only for that playback; the design document is not changed.

**Transition (转场 / 轉場)**: How the prototype window moves from one frame to the next: None, Dissolve (淡入淡出), Push Left/Right/Up/Down (向左/右/上/下推入), or Bottom Sheet (底部弹出 / 底部彈出), with a duration and an easing. Back plays it in reverse.
_Avoid_: animation (reserved for a layer's own animation)

**Animation (动画 / 動畫)**: A layer's motion during prototype playback, started when its frame appears: an *Entrance* (入场 / 進場) — Fade In (淡入), Slide In (滑入), Scale In (缩放进入 / 縮放進入) — or a *Loop* (循环 / 循環) — Spin (旋转 / 旋轉), Pulse (脉冲 / 脈衝), Shimmer (流光 / 流光). Appearance only: it never changes the design document, and the canvas and snapshots show the layer still.
_Avoid_: effect, motion, transition (the move between frames)

**Text sequence (文字序列 / 文字序列)**: A text layer's list of texts shown one after another at a fixed interval during playback, looping or stopping on the last one — the look of a countdown. It triggers nothing; the layer's own text is what editing shows.
_Avoid_: timer, countdown (it does not count real time)

**Prototype window (原型窗口 / 原型視窗)**: The separate window opened by *Play Prototype (播放原型)* that plays the prototype at the frames' actual size; clicks there trigger interactions instead of selecting layers.
_Avoid_: preview mode, present mode

**Annotation (批注 / 批註)**: A plain-text note pinned to a point inside a layer, with a thread of replies, written by a person or an Agent and saved in the project file. It is drawn as a marker on the canvas but is not a layer: it is not in the layers panel or in snapshots. Deleting the layer deletes its annotations ([ADR 0011](docs/adr/0011-annotations-in-the-design-document.md)).
_Avoid_: comment (评论) (suggests a multi-user review workflow, which annotations are not)

**Canvas (画布 / 畫布)**: The pannable, zoomable workspace that displays the design document.

**Layers panel (图层面板 / 圖層面板)**: The layer tree in the left sidebar, used to select, rename, show/hide, and lock layers.

**Properties panel (属性面板 / 屬性面板)**: The Design (设计) and Prototype (原型) tabs of the right inspector: the Design tab edits the selected layer's position, size, auto layout, appearance, fill, stroke, and text; the Prototype tab its interaction, states, scrolling, and animation.

**Selection colors (选区颜色 / 選取範圍顏色)**: The section of the properties panel listing every color the selected layers and all their child layers use — fills, strokes, text colors, and icon colors — merged by hex value and ordered by how often each is used. Changing one replaces it everywhere in the selection as one undo step. Agents read and replace them with `design_list_colors` and `design_replace_color`.

**Font library (字体库 / 字體庫)**: The directory `~/Library/Application Support/fudehand/Fonts` holding font files imported with *Import Font…* or `design_import_font`. Its fonts are registered for the App only, not installed on the system, and not stored in project files: a project file opened on a Mac without the font falls back to the system font.

**MCP server**: A local tool process (`scripts/mcp-server.mjs`) that external AI agents (Claude Code, Codex, DeepSeek Harness, and others) start on demand; it forwards design tools to the running App.

**Agent parity**: The rule that every App feature a person can use, settings included, is also an Agent tool ([ADR 0007](docs/adr/0007-agent-parity.md), `docs/agent-tools.md`).

**Launch window (启动窗口 / 啟動視窗)**: The window shown when the App starts, with three areas: New, Recent, and Templates. It closes once editing begins and can be reopened from *Window → Launch Window (窗口 › 启动窗口)*.
_Avoid_: welcome page (欢迎页), home page (首页)

**Template (模板 / 範本)**: A `.fudehand` design bundled with the App (`native/Resources/Templates/`), used in the launch window to create a new untitled design document; the new document is not linked to the template file, so saving never overwrites the template. The bundled starter templates follow the *design foundations*.
_Avoid_: example (示例), work template (作品模板) (these refer to the removed web-project pipeline)

**Design foundations (基础设计规范 / 基礎設計規範)**: The shared colors, type scale, spacing scale, and corner radii in `docs/design-foundations.md` that the bundled starter templates use and show in their "Design system" frame. A convention people and agents can follow, not part of the design document: changing a value in one design updates nothing else.
_Avoid_: design system (设计系统) for the docs page (the "Design system" frame shows the foundations), theme (主题)

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

**Style library (风格库 / 風格庫)**: The reference files in `styles/` that the Agent reads with `style_list` and `style_read` when the user names a style or asks for a design like a known product. Adapted from third-party analyses of public websites (VoltAgent/awesome-design-md), not official brand systems; not part of the design document.

**Style (风格 / 風格)**: One file in the style library: the colors, fonts (macOS substitutes), type scale, spacing, corner radius, components, and do/don't of one visual direction, written for the layer model.
_Avoid_: theme (主题), design system (设计系统), template (模板) (a template is a bundled `.fudehand` design)

**Agent harness**: The Node child process behind the chat panel (`scripts/agent-chat.mjs`) that runs the conversation loop, calls the model API, and executes tools; it starts only when a message is sent.

**Model provider (模型提供方 / 模型提供者)**: The model API sources available in the chat panel: DeepSeek, Claude, and ChatGPT. DeepSeek uses an OpenAI-compatible API, Claude uses the Anthropic Messages API, and ChatGPT uses OpenAI's Responses API and needs an OpenAI API key.

**UI language (界面语言 / 介面語言)**: The language of the App's own copy, chosen in the app menu's *Language* submenu and remembered across launches. It does not follow the system language and never changes the content of a design document; a new layer's default name is written once, in the UI language at that moment.
