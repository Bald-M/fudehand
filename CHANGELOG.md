# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pull requests should first record notable changes under
`Unreleased`; they are moved into the matching version on release. Write all entries in English. The App UI is
currently Chinese-only, so when an entry names a menu, panel, or button, describe it in English and keep the App's
Chinese label in parentheses the first time it appears, e.g. *File menu → Open Recent (打开最近)*. Use the English term
names from [GLOSSARY.md](GLOSSARY.md).

## [Unreleased]

### Added

- ui-atlas has a macOS app icon featuring a glass globe, a selection frame, and an AI sparkle (#69).

### Changed

- MCP tool descriptions, parameter descriptions, and the layer field guide are now in English; tool names and parameter schemas are unchanged. The chat panel's system prompt is now in English, and the agent replies in the language of the user's latest message instead of always in Simplified Chinese (#82).
- The docs under `docs/` (including the ADRs, design specs, and plans), the template README, and the committed drafts in `.scratch/` are now in English; `docs/localization.md` is marked as a historical record (#81).
- `AGENTS.md` and `GLOSSARY.md` are now in English; each glossary term leads with its English name and keeps the App's Chinese label in parentheses, and serves as the shared translation for the other English docs (#80).
- `CHANGELOG.md` is now written in English, and future entries must be in English; `GLOSSARY.md` lists an English name for each term (#78).
- `README.md` is now in English and is the repository's default README; the Chinese version moved to `README.zh-CN.md`, and both link to each other at the top (#72).
- `CLAUDE.md` is now in English and states the project language convention: docs, code comments, test descriptions, MCP tool descriptions, and error messages in English; App UI copy stays Chinese for now (#79).
- Build script output (`pnpm build:native`, `pnpm test:native`), the non-macOS error, and the control channel startup log are now in English; the `.uiatlas` file kind shown in Finder is now `ui-atlas Project` (#84).

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

[Unreleased]: https://github.com/Bald-M/ui-atlas/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/Bald-M/ui-atlas/releases/tag/v0.0.1
