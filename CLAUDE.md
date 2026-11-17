# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

界面图鉴 (UI Atlas) is a local macOS app for studying UI designs: a SwiftUI + AppKit shell shows Vue/React/HTML study projects ("作品") as fixed-size web frames ("画框") on a pannable, zoomable canvas ("画布"). Docs, UI strings and error messages are in Chinese; terms follow `GLOSSARY.md`. Read `GLOSSARY.md` and the relevant `docs/adr/` before exploring; `docs/macos.md` is the authoritative spec for canvas interaction behavior.

## Commands

Requires macOS 14+, Swift 6 (Command Line Tools are enough, no third-party Swift packages), Node 22.12+, pnpm 11.7.0.

```bash
pnpm install
pnpm dev               # debug-build the app and open it
pnpm build:native      # release build + ad-hoc sign → dist/界面图鉴.app
pnpm test:native       # swift test for native/ (AtlasCoreTests + AtlasAppTests)
pnpm check             # typecheck examples + Vitest (tests/) + build every example
```

Single tests:

```bash
pnpm vitest run tests/launcher.test.ts -t "<name>"
swift test --package-path native --filter AtlasCoreTests.<SuiteOrTest>
```

`pnpm test:native` goes through `scripts/native-swift.mjs`, which pins SwiftPM scratch/cache dirs under `/private/tmp/ui-atlas-native-*` (override with `UI_ATLAS_SWIFT_SCRATCH` / `UI_ATLAS_SWIFT_MODULE_CACHE`) and passes `--disable-sandbox`; never run two Swift builds on the same scratch dir. Node tests spawn real HTTP servers and child processes, so they need loopback networking — a sandbox that blocks listening on localhost makes them fail spuriously.

`UI_ATLAS_FRAME_LOG=1` makes the app print `[frame] hitches=N frames=M` once a second for pan/zoom performance work.

## Architecture

**`catalog.json` is the single source of truth** for projects, frames, default layout and preview launch config (`preview.cwd/command/port/baseUrl`). Each example's `vite.config.ts` reads its own port/host from it with `readFileSync` (not `import`, to avoid Vite restarting every service on catalog edits). Catalog validation is implemented twice — `scripts/launcher.mjs` (Node) and `native/Sources/AtlasCore/Catalog.swift` (Swift) — and both test suites run the shared cases in `tests/fixtures/catalog-conformance.json`. Any rule change must update both sides and the fixture.

**Process model.** The Swift app (`PreviewSession`) spawns `node scripts/native-preview.mjs --root <repo>`, which uses `launcher.mjs` to start every `enabled` example's dev server, waits for HTTP 2xx, then prints `UI_ATLAS_READY`. The app owns that child's stdin pipe; EOF (quit or crash) tears down all preview process groups. The launcher never kills foreign processes holding a port and never picks another port. `native-build.mjs` writes the repo path, Node path and PATH into the bundle's `Contents/Resources/workspace.json`, so the built app depends on this checkout and its Node install.

**Native targets** (`native/Package.swift`, Swift 5 language mode):
- `AtlasCore` — pure, AppKit-free logic: catalog model/validation, geometry and viewport math, layout persistence, snapping, scroll routing, viewport animation, and `CanvasInteraction` (a state machine that turns pointer events + `HitTarget` into `InteractionEffect`s). Put testable interaction rules here.
- `AtlasApp` — SwiftUI shell (`AtlasApp`, `WorkspaceView`), `AtlasStore` (app state, UserDefaults persistence of theme/workspace/per-project positions and viewport), and the AppKit canvas: `NativeCanvas` (NSViewRepresentable bridge) → `AtlasCanvasView` (input handling, applies interaction effects), `CanvasViewport` (pans move `world.bounds`; zooms render as a GPU transform and commit when settled), `CanvasGrid`, `CanvasOverlay` (selection/marquee/guides, never takes input), and `PreviewFrameView` (one WKWebView per frame, injected Esc script).

The canvas owns the live viewport and selection and reports only settled values back to `AtlasStore`; the store pushes one-off changes down via token-bearing requests (`ViewportRequest`, `positionsToken`, `reloadToken`) — a new token means "apply once". Frames are scaled visually as a whole; each web view keeps its configured CSS viewport size, so responsive breakpoints don't change with zoom.

**Examples** live in `examples/*` (pnpm workspace). The app loads them directly from their own ports (no proxy). There is no backend and no static site bundle.

## Conventions

- Remote: `origin` → https://github.com/Bald-M/ui-atlas (default branch `main`). No CI or deploy is configured, so local checks are the gate. Deliver on a task branch, push it and open a PR into `main`.
- Specs and task records go in `.scratch/<feature>/spec.md` and `.scratch/<feature>/issues/NN-slug.md` (with `Status:` / `Blocked by:` lines), per `docs/agents/issue-tracker.md`.
- Record new terms in `GLOSSARY.md` and architectural decisions in `docs/adr/`. ADR 0002 removed the browser shell entirely — don't reintroduce `apps/atlas`, `dev:web`, a 4400 shell port or an iframe bridge.
- UI changes should be checked in the real app in both light and dark appearance; evidence screenshots go in `docs/evidence/`.
