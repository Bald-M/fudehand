# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

Fudehand is a local, native macOS AI design tool: a SwiftUI + AppKit shell renders a "design document" made of layers with Core Animation on a pannable, zoomable "canvas". People and AI Agents edit the same document, and designs are saved as `.fudehand` project files (JSON). Terminology follows `GLOSSARY.md`. Read `GLOSSARY.md` and the relevant `docs/adr/` (especially ADR 0006) before exploring the code; `docs/macos.md` is the authoritative spec for canvas interaction behavior.

Language: project docs (README, CHANGELOG, `GLOSSARY.md`, `docs/`, ADRs), code comments, test descriptions, MCP tool descriptions, and error messages are in English; write any new content of these kinds in English too. App UI copy is localized into US English (the default and the source language), British English, Simplified Chinese, and Traditional Chinese: never hard-code UI copy; write `L("English text")` and add the key to all four `Localizable.strings` tables in `native/Sources/FudehandCore/Resources/`, using the term names in `GLOSSARY.md` (tests fail on an `L("…")` call without a table entry, on tables whose keys differ, and on hard-coded Chinese copy in the UI source files listed in `LocalizationTests.swift` — add new UI files to that list). Control-channel protocol, field-validation, and command errors are not localized.

## Workflow: superpowers skills

This repository requires working with the [superpowers](https://github.com/obra/superpowers) skills. At the start of every conversation, before doing anything (including asking clarifying questions or reading code), invoke `superpowers:using-superpowers` first, then invoke the skill matching the task and follow it strictly. Invoke a skill whenever there is even a small chance it applies; do not skip it because "the task is too simple". Common mappings:

- New feature, new behavior, any creative or planning work → `superpowers:brainstorming` first, then `superpowers:writing-plans`
- Implementing a plan → `superpowers:executing-plans`, or `superpowers:subagent-driven-development` when there are independent subtasks
- Before writing implementation code → `superpowers:test-driven-development`
- Bugs, test failures, unexpected behavior → `superpowers:systematic-debugging` before changing anything
- Development that needs isolation → `superpowers:using-git-worktrees`
- Before claiming completion, committing, or opening a PR → `superpowers:verification-before-completion`
- Requesting review after finishing → `superpowers:requesting-code-review`; receiving review feedback → `superpowers:receiving-code-review`
- Implementation done, deciding how to integrate → `superpowers:finishing-a-development-branch`

Explicit user instructions and the conventions in this file take precedence over skill workflows; skip a skill only when the user explicitly says not to use it.

## Commands

Requires macOS 14+, Swift 6 (the Command Line Tools are enough; no third-party Swift packages), Node 22.12+, and pnpm 11.7.0.

```bash
pnpm install
pnpm dev               # build the app in debug and open it
pnpm build:native      # release build + ad-hoc signing → dist/Fudehand.app
pnpm test:native       # run swift test on native/ (FudehandCoreTests + FudehandAppTests)
pnpm bench:native      # release-build canvas drag/hover and layer selection benchmarks on 510–5100 layers (prints [bench] lines)
pnpm check             # Vitest (tests/): MCP tools, MCP server, chat harness
pnpm mcp               # start the Fudehand MCP server over stdio (usually launched by the Agent)
```

Run a single test:

```bash
pnpm vitest run tests/control-tools.test.ts -t "<name>"
swift test --package-path native --filter FudehandCoreTests.<SuiteOrTest>
```

`pnpm test:native` runs through `scripts/native-swift.mjs`, which pins SwiftPM's scratch/cache directories under `/private/tmp/fudehand-native-*` (override with `FUDEHAND_SWIFT_SCRATCH` / `FUDEHAND_SWIFT_MODULE_CACHE`) and passes `--disable-sandbox`; do not run two Swift builds on the same scratch directory at once. The Node tests start real local sockets, HTTP servers, and child processes, so they need loopback networking — a sandbox that forbids listening on localhost makes them fail spuriously.

With `FUDEHAND_FRAME_LOG=1` set, the app prints `[frame] hitches=N frames=M` once per second, for tuning pan/zoom performance.

## Architecture

**The App is the sole owner of the design document** (ADR 0006). `FudehandStore` owns the `DesignEditor` (document + undo history); edits from the canvas, layers panel, properties panel, and control channel all go through it, and human and Agent edits share one undo history. On launch the App first shows the launch window (New, Open Recent, Templates); the editor window opens, and the launch window closes, only once editing starts (see "启动与构建" (Startup and build) in `docs/macos.md`). Launching starts no Node process; the harness starts only when the chat panel sends a message. `native-build.mjs` writes the repository path, Node path, and PATH into the app bundle's `Contents/Resources/workspace.json` so the chat panel can find `scripts/agent-chat.mjs`.

**Native targets** (`native/Package.swift`, Swift 5 language mode):
- `FudehandCore` — pure logic, no AppKit dependency: `DesignDocument` (layer model, `.fudehand` reading/writing and version validation), `DesignJSON` (JSON ↔ node conversion, field validation, partial field patches — file loading and Agent create/update share this single validation), `DesignLayout` (auto layout, text auto-sizing, group shrinking; text measurement is injected by the App), `DesignEditor` (tree operations and undo history; a continuous gesture is recorded as one step), `DesignIndex` (id → tree position and absolute rectangle, built once per document change by the store and shared with the canvas; per-event code looks layers up here instead of searching the tree), `DesignHitTest` (Figma-style click selection rules), `CanvasInteraction` (a state machine turning pointer events + `HitTarget` into `InteractionEffect`: move, resize handles, marquee selection, create, pan), geometry and viewport, snapping, viewport animation, `ControlProtocol`, `Localization` (`AppLanguage`, the string tables, and `L(_:)`; the store publishes the chosen language and each window passes it down as `\.locale`). Testable rules belong here.
- `FudehandApp` — the SwiftUI shell (`FudehandApp` menus, `WorkspaceView`, `LayersPanel`, `InspectorPanel`, `ChatPanel`), `FudehandStore`, and the AppKit canvas: `NativeCanvas` (NSViewRepresentable bridge) → `FudehandCanvasView` (handles input and hands edits to the store via the `CanvasHost` protocol), `DesignRenderer` (document → CALayer tree, updated incrementally by id; `snapshotPNG` for offscreen snapshots), `TextMetrics`/`TextLayer` (CoreText measuring and drawing share the same typesetting), `CanvasViewport` (panning moves `world.bounds`; zooming renders with a GPU transform and commits once stable, then updates `contentsScale` for text/images), `CanvasGrid`, `CanvasOverlay` (selection box, handles, top-level frame names, marquee, guides; never receives input).

The store calls `canvas.show(index)` (the document with its `DesignIndex`) directly on every document change (during a drag this path runs every frame, bypassing SwiftUI); the `@Published document` that the panels read is not updated during a continuous gesture and is updated once when it ends. The canvas still owns the live viewport value and reports only stable values back to the store; the store pushes one-off viewport changes down with a token-tagged `ViewportRequest`.

**Agent integration** (ADR 0003, 0006). `scripts/fudehand-tools.mjs` is the only tool implementation, shared by the MCP server (`scripts/mcp-server.mjs`, registered as `fudehand` in `.mcp.json`) and the App chat panel's Agent harness (`scripts/agent-chat.mjs`, JSON-lines protocol, model adapters in `agent-providers.mjs`). Every tool is forwarded through `scripts/control-client.mjs` to the App's control channel (`~/Library/Application Support/fudehand/control.sock`, override with `FUDEHAND_CONTROL_SOCKET`); the Node side only reads `image.path` into base64 and resolves relative file paths against the repository directory, and does no field validation. The exception is the style library tools (`style_list`, `style_read` in `scripts/style-library.mjs`), which read reference files in `styles/` in Node and never touch the design document (ADR 0008). The protocol lives in `FudehandCore/ControlProtocol.swift`, the listener in `FudehandApp/ControlServer.swift`, and command dispatch in `ControlCommands.swift`. The chat panel's API key is stored in the Keychain and passed to the harness only through the `FUDEHAND_API_KEY` environment variable.

## Conventions

- Remote: `origin` → https://github.com/Bald-M/fudehand (default branch `main`). No CI or deployment is configured; local checks are the gate. Deliver on a task branch, push, then open a PR against `main`.
- Create and track tasks directly in GitHub Issues with `gh issue`; do not keep local task records. `.scratch/<feature>/` is only for drafting longer specs or plans.
- Record new terms in `GLOSSARY.md` and architecture decisions in `docs/adr/`. ADR 0002 fully removed the browser shell and ADR 0006 removed the web-work pipeline — do not reintroduce `apps/atlas`, `catalog.json`, `examples/`, the preview launcher, or WKWebView frames.
- Agent parity (ADR 0007): every App feature, settings included, is also an Agent tool. A PR that adds or changes a feature adds or changes its tool, its tests, and the coverage table in `docs/agent-tools.md`, following the rules there.
- UI changes must be checked in the real app in both light and dark appearance; put evidence screenshots in `docs/evidence/`.
