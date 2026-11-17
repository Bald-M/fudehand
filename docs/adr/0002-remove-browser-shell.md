# Remove the Browser-Compatible Version

2026-11-06: the user asked to remove the browser-compatible version completely. The native macOS App (see [0001](0001-native-macos-shell.md)) is the only shell: delete the `apps/atlas` Vue canvas, the `pnpm dev:web` entry point and `scripts/dev.mjs`, and the `packages/preview-bridge` Esc bridge that only served the iframe canvas. The native App injects its own Esc exit script into WKWebView, so examples do not need to integrate any bridge.

`catalog.json` no longer contains the `shell` field (the 4400 canvas port), and its version stays 1; a leftover `shell` in old configurations is ignored by both validators. Preferences in browser localStorage are not migrated. The browser version's requirements baseline and acceptance record (`docs/implementation-plan.md`, `docs/verification.md`) are deleted along with it and remain available in Git history.
