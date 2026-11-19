# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pull requests should first record notable changes under
`Unreleased`; they are moved into the matching version on release. Write all entries in English. When an entry
names a menu, panel, or button, use its US English label, e.g. *File menu → Open Recent*. Use the English term
names from [GLOSSARY.md](GLOSSARY.md).

## [Unreleased]

### Added

- A style library for the Agent: when you name a style or ask for a design like a known product (for example Linear, Stripe, or Notion), the Agent reads that style's colors, fonts, type scale, spacing, and corner radius before building, and says so when the library has none. Ten styles are included, adapted from VoltAgent/awesome-design-md with macOS fonts; they are third-party analyses, not official brand systems. Both the chat panel and the MCP server get the new `style_list` and `style_read` tools.
- Icon layers with four built-in icon libraries: SF Symbols (`sf`, drawn by the system), Material Symbols in three styles (`material-outlined`, `material-rounded`, `material-sharp`, with `.fill` variants), WeUI (`weui`), and Lucide (`lucide`). An icon layer stores only `library/name` and a color, is drawn sharp at any zoom, and shows a placeholder when this Mac does not have the icon. The layers panel lists icon layers, and the properties panel shows the icon name and changes its color. Agents search with `design_search_icons` and create icon layers through `design_create_node`; an unknown icon name is an error that lists similar names, and the design guidance tells Agents to use real icons from the library of the prototype's platform. Project files are now format version 5; older files still open (#155).
- Prototype animation: any layer can have an *Animation* — an entrance (*Fade In*, *Slide In*, *Scale In*) or a loop (*Spin*, *Pulse*, *Shimmer*) with a duration, delay, easing, and repeat count — and a text layer can have a *Text Sequence* that shows a list of texts in turn, such as a countdown. They play in the prototype window when the layer's frame appears, and *Preview* in the properties panel plays them without the prototype; the canvas and snapshots stay still. Agents set `animation` and `text.sequence` through `design_create_node` / `design_update_node`. Project files are now format version 3; older files still open (#151).
- Prototypes now work within a screen: a frame can scroll vertically or horizontally in the prototype window, with layers fixed in place above the content; layers can have *While hovered* and *While pressed* looks; *Open Overlay* shows a frame over the current one (center, bottom, or below the clicked layer, with an optional background and click-outside-to-close) and *Close Overlay* closes it; *Toggle Visibility* shows and hides layers for tabs, switches, and checkboxes. All of it is set in the Prototype section of the properties panel or by Agents through `design_create_node` / `design_update_node`. Project files are now format version 4; older files open unchanged (#150).

- A *Font* menu in the text section of the properties panel, listing *System Default*, the installed font families, and those in the font library; a family the Mac does not have is shown as missing. *Import Font…* adds `.ttf`, `.otf`, and `.ttc` files to the font library, which only Fudehand uses. Agents get `design_list_fonts` and `design_import_font`.
- Next-message prediction in the chat panel: after a reply ends, the empty input shows the message you are likely to send next as its placeholder, and Tab puts it in the input to edit or send. The prediction is a separate short model request that is kept out of the conversation.
- Slash commands in the chat panel: typing `/` at the start of the input opens a command menu that narrows as you type and is driven by the arrow keys, Return, Esc, or the mouse. `/plan` switches the conversation to plan mode, where the Agent can only read the design document and replies with a plan that *Run Plan* carries out; `/goal` switches to goal mode, where the Agent keeps working on the goal until it reports it done or is stopped; `/new` starts a conversation, `/clear` empties the current one, `/compact` compacts it, and `/model` lists the models to switch to. A tag above the input shows the mode and leaves it. An unknown command is reported under the input and is not sent to the model.
- Chat panel: a context ring in the input shows how much of the model's context window the conversation takes up, with the numbers on hover; it turns orange and then red near the limit and follows the selected model. The window comes from the provider's model list, so use *Reload Model List* once to fill it in (#104).
- Image layers accept SVG as well as PNG and JPEG, for brand icons and other vector art. *Canvas → Insert Image…*, the inspector's replace-image button, and the Agent's `image.path` / `image.data` take `.svg`; the SVG source is saved in the project file unchanged and redrawn sharp as you zoom in. A new SVG layer starts at the size the SVG declares (#148).
- Chat panel: the `/compact` slash command replaces the earlier messages the model sees with a summary, so a long conversation can continue; the messages stay in the panel, under a *Context compacted* row that shows the summary (#104).

### Changed

- The Agent's design guidance gains design principles (content, hierarchy and rhythm, type and color, tropes to avoid, simplicity, contrast and tap-target size) and a self-review checklist to go through after building a screen, adapted from the community-reconstructed Claude Design system prompt in Trystan-SA/claude-design-system-prompt (MIT). The chat panel gets all of it; MCP clients that cut a server's instructions off at about 2,048 characters, such as Claude Code, still get the earlier process and quality floor whole, since those come first.
- Conversations now belong to the design document they were held about. Opening a project file restores its conversation tabs, with their messages and each conversation's model, and no other document's conversations are shown; an untitled document keeps its conversations until it is replaced or the App quits, and takes them along on its first save. Conversations saved by earlier versions are not attached to any document and no longer appear in *Conversation history*.
- **Breaking:** the product is renamed from ui-atlas to Fudehand. The App is now `Fudehand.app` (bundle identifier `local.fudehand.native`), project files use the `.fudehand` extension, the MCP server is registered as `fudehand`, the control channel and saved conversations live under `~/Library/Application Support/fudehand`, and the `UI_ATLAS_*` environment variables are now `FUDEHAND_*`. Nothing is migrated: rename existing `.uiatlas` files to `.fudehand` to open them, reconnect Agents in *MCP Connectors…*, and enter API keys again in *Model settings*. Earlier entries below keep the old name.
- The app icon is now an ink-wash painting: mountains receding in three ink tones under a red sun.
- *MCP Connectors…* shows each Agent's icon (Claude, Codex, the DeepSeek whale) beside its name, with the status dot as a badge on the icon; an Agent whose CLI is not installed has a dimmed, gray icon (#153).
- Selecting a layer is faster, most noticeably in large documents: the properties panel keeps its controls when the selection moves to another layer instead of rebuilding them, and only the layer rows on screen and the inspector redraw. On a 5,100-layer document a selection now settles in about 10 ms instead of about 40 ms. `pnpm bench:native` also measures it.

### Fixed

- `design_snapshot` drew image layers upside down; images now appear upright in snapshots.

## [0.0.3] - 2026-11-18

### Summary

This release rounds out the in-app chat panel: replies stream in and render Markdown, conversations open in tabs and are saved, several model providers can be set up side by side, and each reply shows its token usage. Agents get shared design guidance, and DeepSeek Harness joins the MCP connectors. The canvas tools moved to a toolbar at the bottom of the canvas, dragging stays fast in large documents, and a batch of properties panel, layout, canvas, file, and validation defects found after v0.0.2 is fixed.

### Added

- MCP connector: *MCP Connectors…* now lists DeepSeek Harness too. *Connect* adds the MCP server to its home patch file (`~/.dsh/cordis.patch.yml`) in a marked block and *Disconnect* removes only that block; the app is found in `/Applications` even when `dsh` is not on the `PATH` (#74).
- Chat panel: replies stream in as they are generated, and stopping a reply keeps the text received so far (#29).
- Chat panel: assistant replies render Markdown — headings, lists, inline code, links, quotes, and code blocks with a *Copy code* button (#29).
- Chat panel: conversations are saved on this Mac (`~/Library/Application Support/ui-atlas/chats`) and reopened after a relaunch; the header has *New conversation* and a *Conversation history* menu (#29).
- Chat panel: the selected layers appear above the input as removable context tags and are passed to the Agent with the message (#29).
- Chat panel: *Copy message* and *Regenerate* on assistant replies, and *Edit and resend* on the last user message (#29).
- Chat panel: *Model settings* lists every model provider with its own API key, base URL, and model, and *Test* checks a key; the model menu lists every provider that has a key and switches provider and model in one step (#133).
- Agent: the chat panel's Agent and Agents connected through the MCP server now get the same design guidance. For a new or redone screen the Agent states what it assumes about the product, plans the colors, fonts, and layout, checks that plan against the request, builds, and then reviews the result; real copy, at most two font families, readable contrast, and consistent spacing apply however short the request is. A visual direction given in the request always takes precedence. The guidance is adapted from the `frontend-design` skill in [anthropics/skills](https://github.com/anthropics/skills/tree/main/skills/frontend-design) (Apache-2.0) (#108).
- Chat panel: conversations open in tabs at the top of the panel, with *New conversation* (+), switching, and *Close conversation*. Each open conversation has its own messages, context, and model, and a new one starts without the others' context. One conversation can keep replying while you work in another, its tab showing a dot; stopping, regenerating, and editing act only on the current conversation. Closing a tab stops its reply but keeps the conversation in *Conversation history* (#100).
- Chat panel: each reply shows its total tokens (input plus output across all of that reply's model requests) at the end of its action row, with input, cached, and output on hover. The numbers are the usage the model API reports; a reply shows none when a request did not report usage. Usage is saved with the conversation (#139).

### Changed

- Dragging and hovering on the canvas stay fast in large documents: layers are looked up in an index built once per document change instead of by searching the whole tree for each one. On a 5,100-layer document a drag event drops from about 39 ms to under 4 ms and a hover hit test from 0.65 ms to 0.01 ms; `pnpm bench:native` reruns the measurement (#52).
- Chat panel: a tool call and its result are one card with a running, succeeded, or failed state, opening to show the arguments and the result; consecutive calls fold into "Ran N steps" (#29).
- Chat panel: the input is a bordered box that grows up to 8 lines, with the model menu and the send button below it. Return sends and Shift-Return starts a new line (#29).
- Chat panel: model providers are shown as DeepSeek, Claude, and ChatGPT (#133).
- Chat panel: changes in *Model settings*, including removing a key, apply only on *Save* (#133).
- Chat panel: the transcript follows new text only while you are at the bottom, and shows *Scroll to bottom* once you scroll up (#29).
- Chat panel: changing the model keeps the conversation; the new model is given the earlier messages (#29).
- `README.md` and `README.zh-CN.md` are rewritten and reorganized: a highlights list, requirements, a quick start, one section on working with AI agents (with the tools as a table), and a development section. Stale statements are corrected, such as error messages being in Chinese.
- Canvas: the canvas tools (Move, Hand, Frame, Rectangle, Ellipse, Text) and *Insert Image* moved from the window toolbar to a toolbar floating at the bottom center of the canvas; zoom, *Appearance*, and *Inspector* stay in the window toolbar (#138).
- Groups in an auto layout frame ignore fill and stretch sizing: a group's size always equals the union of its children, and it takes no share of the remaining space. The properties panel no longer shows the width and height sizing selectors for a group (#60).
- Layers panel: holding ⌘ or Shift while double-clicking a row adds to or removes from the selection instead of starting a rename (#140).

### Fixed

- Properties panel number fields no longer rewrite a value when they only gain and lose focus. Previously, focusing and leaving X, Y, W, H, or any other number field rounded the value to the one decimal place shown, added an undo step, and marked the document as edited; passing through W or H also turned off a text layer's auto sizing (#57).
- In the chat panel, the model now receives the image that `design_snapshot` returns when the model provider is Anthropic Claude or OpenAI; before, only the accompanying text was sent, so the model never saw the snapshot. With DeepSeek (the OpenAI-compatible API, which cannot carry an image in a tool result) the model is told that the image was left out, and its instructions now say to check changes by reading the layers back (#59).
- Auto layout: a group set to fill or stretch was resized while its children stayed the same, so its selection box, click area, and size no longer matched what was visible (#60).
- Creation tools: dragging in a straight horizontal or vertical line no longer creates a zero-size layer that cannot be clicked; a dragged layer is at least 1×1. Dragging out exactly 100×100 is treated as a drag instead of a single click (#62).
- A document no longer shows as edited, or asks to be saved, when its content is back to what was last saved, such as after dragging a layer back to where it was or undoing back to the save point; redoing past the save point shows it as edited again (#63, #75).
- Validation: a color with a sign, such as `#+12345`, is rejected instead of being read as another color, and a fractional `text.fontWeight`, such as 450.9, is rejected instead of being cut down to 450. This applies both to opening a project file and to Agent edits (#64).
- Chat panel: the assistant now names the model it actually runs on when asked; with DeepSeek it used to say it was based on Claude (#131).
- Chat panel: when the saved API key is no longer in the Keychain, for example after being deleted outside the App, the panel shows *Set API Key…* again instead of failing on send while *Model settings* still showed the key as saved.
- Layers panel: a row is selected as soon as the mouse button goes down instead of after the double-click interval, and rows highlight on hover. Hovering a row outlines its layer on the canvas, and hovering a layer on the canvas highlights its row (#140).

## [0.0.2] - 2026-11-17

### Summary

The App now comes in four UI languages and starts in US English, and has a macOS app icon. Project docs, code comments, MCP tool descriptions, and error messages moved to English. This release also fixes several agent, chat panel, and project file defects found after v0.0.1.

### Added

- UI languages: the App now comes in US English, British English, Simplified Chinese, and Traditional Chinese, chosen in the app menu's *Language* submenu. The choice applies immediately, is remembered across launches, and does not follow the system language; system-provided menu items (About, Quit, Edit, Window) switch at the next launch (#89).
- ui-atlas has a macOS app icon featuring a glass globe, a selection frame, and an AI sparkle (#69).

### Changed

- **The App now starts in US English.** It used to be Simplified Chinese only; choose *Language → 简体中文* to switch back (#89).
- New layers get their default name (Frame, Rectangle, …) in the UI language at the time they are created; existing layer names are never changed (#89).
- The confirmation shown before discarding unsaved changes no longer names the action that triggered it (#89).
- MCP tool descriptions, parameter descriptions, and the layer field guide are now in English; tool names and parameter schemas are unchanged. The chat panel's system prompt is now in English, and the agent replies in the language of the user's latest message instead of always in Simplified Chinese (#82).
- The docs under `docs/` (including the ADRs, design specs, and plans), the template README, and the committed drafts in `.scratch/` are now in English; `docs/localization.md` is marked as a historical record (#81).
- Error messages returned to agents and shown in the App are now in English: control channel argument errors, layer field validation, project file loading, editing commands (undo, save, missing layers), snapshots, the Node control client, and model API errors in the chat panel (#83).
- `AGENTS.md` and `GLOSSARY.md` are now in English; each glossary term leads with its English name and keeps the App's Chinese label in parentheses, and serves as the shared translation for the other English docs (#80).
- `CHANGELOG.md` is now written in English, and future entries must be in English; `GLOSSARY.md` lists an English name for each term (#78).
- `README.md` is now in English and is the repository's default README; the Chinese version moved to `README.zh-CN.md`, and both link to each other at the top (#72).
- `CLAUDE.md` is now in English and states the project language convention: docs, code comments, test descriptions, MCP tool descriptions, and error messages in English; App UI copy stays Chinese for now (#79).
- Code comments, test names, and test data in `native/`, `scripts/`, and `tests/` are now in English; Chinese test data remains only where a test checks Chinese or multi-byte text, with a comment saying so (#85).
- The text that accompanies a `design_snapshot` image and the placeholder that stands in for image data when a layer is read (`<N bytes>`) are now in English.
- Build script output (`pnpm build:native`, `pnpm test:native`), the non-macOS error, and the control channel startup log are now in English; the `.uiatlas` file kind shown in Finder is now `ui-atlas Project` (#84).

### Fixed

- Changing the model settings or deleting the saved API key while a reply is in progress no longer leaves the chat panel stuck on "Replying…"; the running reply is ended as stopped, and you can send, clear, and stop again (#55).
- Agents can insert images of up to about 24 MB through `design_create_node` / `design_update_node`: the control channel's request limit rose from 1 MB to 32 MB (about 760 KB of image before). A request over the limit now gets an error that says it is too large and carries the request id, and the connection stays usable (#53).
- A project file can always be reopened after editing: moving or laying out a layer to an extreme position used to save coordinates or sizes that failed validation on open. Layer x/y are now clamped to ±1,000,000 and width/height to 0–1,000,000 after every edit; a layer past the limit stops at the limit (#56).
- `~` and `~/…` in agent tool paths (`design_open_document`, `design_save_document`, and a layer's `image.path`) now expand to the user's home directory instead of resolving under the ui-atlas repository directory (#58).
- Chat panel with OpenAI: the default model is now `gpt-5.3-codex` (the previous default, `gpt-5-codex`, returned 404), and function tools are sent with `strict: false` (#61).
- Chat panel with Anthropic: the output limit rose from 4,096 to 16,000 tokens so larger design tasks are no longer cut off, thinking blocks are passed back during tool use, and a refused or paused reply now shows an error instead of ending silently (#61).

## [0.0.1] - 2026-11-17

### Summary

The first release of ui-atlas: a native macOS AI design tool that runs locally. The canvas renders a design document made of layers with Core Animation, with Figma-style interaction; people and AI agents (through the MCP server or the in-app chat panel) edit the same document and share one undo history, and designs are saved as `.uiatlas` project files. Early development centered on frames that displayed web projects; starting with #46 it switched to native design documents and the web-project pipeline was removed. That history is kept below in chronological order. The build is an ad-hoc signed app built on your own machine, and it is not notarized.

### Added

- Native macOS app (SwiftUI + AppKit): displays Vue/React/HTML projects in frames with a fixed CSS viewport on a pannable, zoomable canvas, with UI and examples in Simplified Chinese (ADR 0001).
- Figma-style canvas interaction: frame selection, marquee selection, drag snapping with guides, viewport animation, and gesture-locked scroll routing (#1).
- MCP server (`pnpm mcp`, registered as `ui-atlas` in `.mcp.json`): read-only project tools (#12), write tools for frames and projects (#13), canvas control and frame screenshot tools (#17), and tools for frame console output, page reading, and basic interaction (#37).
- Local App control channel that lets agent tools operate the canvas (#16).
- In-app chat panel (对话) and Agent harness (#26); model settings fetch the model list automatically, and the API key is masked in the UI and stored only in the Keychain (#34).
- On-demand project servers: a project's dev server starts only when the project is selected, and a single failed project can be retried on its own (#39, ADR 0004).
- The sidebar shows project thumbnails and last-modified times, sorts by directory order or most recently modified, and supports pinning from the context menu (#43).
- The cursor turns into a grab hand as soon as Space is held (#31).
- Native design documents with a Figma-style workflow: frames, rectangles, ellipses, text, images, groups, and auto layout, rendered directly with Core Animation; canvas selection, moving, resize handles, and creation tools; the layers panel and properties panel (设计); `.uiatlas` project files (JSON with a format version); an undo history shared by people and agents (#46, ADR 0006).
- Agent design tools `design_*`, `canvas_*`, and `design_snapshot`, which edit the design document through the control channel and take screenshots for checking (#46).
- Launch window (启动窗口): create a new design document, Recent (最近打开), which lists up to 10 items and is shared with *File menu → Open Recent (打开最近)*, and built-in templates (模板) (#54).
- MCP connector: one click in the app menu's *MCP Connectors… (MCP 连接器…)* connects the MCP server to Claude Code or Codex, or disconnects it (#51).

### Changed

- Mouse wheel and trackpad scrolling always pan the canvas; ⌥ + scroll scrolls long pages inside a frame (#42).
- ⌘ / ⌃ + mouse wheel zooms by physical direction, regardless of the system natural scrolling setting (#38, #41).
- Projects open only in App frames: *Open in Browser (在浏览器打开)* was removed, and project servers reject requests without a preview token (#44, ADR 0005).
- Web pages inside frames hide their scrollbars (#28).
- The product name is unified as ui-atlas, and the former Chinese name (界面图鉴) is no longer used (#45).
- Task tracking moved to GitHub Issues, with issue priority assigned by the agent (#8, #10, #11).
- The version is unified as 0.0.1 (`package.json`, the app's Info.plist, and the MCP server); the README was rewritten for the native design tool, adding install and build instructions, a description of `.uiatlas` project files, and a screenshot of the main window (#67).

### Removed

- The web-project pipeline: WKWebView frames, the preview launcher and project servers, `catalog.json`, `examples/`, and the project- and frame-related MCP tools and sidebar thumbnails; ADR 0004 and 0005 are superseded by ADR 0006 (#46).
- The browser-compatible web shell (`apps/atlas`, `dev:web`, port 4400, and the iframe bridge); see ADR 0002.
- The device-type buttons in the canvas bottom bar (#40).

### Fixed

- The Open panel could not select `.uiatlas` project files: the App now exports the project file type and registers as its editor, so double-clicking in Finder opens them too (#50).
- Disabled WebKit's automatic content insets in frames, so web pages no longer stretch while panning (#25).

### Upgrade Notes

- Starting with #46, `catalog.json` and web projects are no longer read; replace project and frame tools in agent configurations with the `design_*` design tools (see the README). `pnpm check` runs only Vitest.
- After the rename, the app bundle is `dist/ui-atlas.app`, the control channel lives at `~/Library/Application Support/ui-atlas/control.sock`, and the Keychain service name is `ui-atlas.agent`. A chat panel API key saved in the Keychain before the rename must be entered again (#45).
- See the [README](README.md) for Codex approval settings for MCP tool calls (#33); see [ADR 0003](docs/adr/0003-agent-mcp.md) for the design of MCP, the control channel, and the chat panel (#27).

[Unreleased]: https://github.com/Bald-M/ui-atlas/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/Bald-M/ui-atlas/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/Bald-M/ui-atlas/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/Bald-M/ui-atlas/releases/tag/v0.0.1
