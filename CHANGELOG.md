# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pull requests should first record notable changes under
`Unreleased`; they are moved into the matching version on release. Write all entries in English. When an entry
names a menu, panel, or button, use its US English label, e.g. *File menu → Open Recent*. Use the English term
names from [GLOSSARY.md](GLOSSARY.md).

## [Unreleased]

### Changed

- `README.md` and `README.zh-CN.md` are rewritten and reorganized: a highlights list, requirements, a quick start, one section on working with AI agents (with the tools as a table), and a development section. Stale statements are corrected, such as error messages being in Chinese.

### Fixed

- Properties panel number fields no longer rewrite a value when they only gain and lose focus. Previously, focusing and leaving X, Y, W, H, or any other number field rounded the value to the one decimal place shown, added an undo step, and marked the document as edited; passing through W or H also turned off a text layer's auto sizing (#57).

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

[Unreleased]: https://github.com/Bald-M/ui-atlas/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/Bald-M/ui-atlas/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/Bald-M/ui-atlas/releases/tag/v0.0.1
