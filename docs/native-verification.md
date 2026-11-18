# Native Migration Verification Record

> Historical record: the browser server and port 4400 mentioned here were removed along with the browser-compatible version; see [ADR 0002](adr/0002-remove-browser-shell.md).

Environment: 2026-11-06, Apple Silicon, macOS 15.2, Command Line Tools Swift 6.0.3, Node 22.22.2. Full Xcode not installed; minimum deployment target macOS 14.

## Automated Checks

- `pnpm check`: passed the web workspace type check, 24 Vitest tests, and three web builds, including 4 new real-process tests for the native service entry point.
- The default execution sandbox forbids listening on local ports, so the first HTTP test run failed; rerunning in an environment that allows loopback passed everything, with no tests deleted or skipped.
- `pnpm test:native`: 7 Swift Testing tests passed, covering valid configuration, invalid configuration groups, geometry, layout restoration, and a regression where resizing the window after switching web projects keeps the user's viewpoint.
- `pnpm build:native`: Release compile, link, and App packaging succeeded; `codesign --verify --deep --strict dist/Fudehand.app` passed.

## Real App Acceptance

- In the real macOS App, loaded the Vue example's three frame sizes and the React example; switching web projects, focusing the mobile frame, and the empty search-result state all worked.
- Checked both the system light and dark appearances; evidence in `docs/evidence/native-light.png` and `native-dark.png`.
- When the old browser server held the port, EADDRINUSE and a retry were shown; after normally stopping the old launcher confirmed to belong to this repository, the App's retry succeeded.
- After quitting with ⌘Q, nothing was listening on 4400, 4401, or 4402; reopening the App restored the most recent web project, theme, and viewpoint, and the examples became ready automatically.
- Real web-dialog acceptance found that the native responder chain handled Escape too early; fixed so that during interaction the web bridge decides whether to exit. Both the real App and an NSWindow keyboard regression confirmed that the first Escape closes the dialog and keeps interaction, and the second exits interaction.
- Loading an empty folder via Open Project Folder (打开项目目录) showed No Enabled Web Projects (没有已启用的作品); choosing an invalid configuration with missing fields showed an error and kept the previous valid folder; switching back to the real project afterwards became ready normally.
- Checked 1440×940 and roughly 940×672 windows: in the narrower window the description scrolls independently, and the sidebar status and the canvas's bottom controls stay visible; also checked Fit All on the canvas after resizing the window with the system zoom.
- A local-state regression probe ran the same test against FudehandStore before and after the fix: switch to an uncached web project → 100% → resize the window. The old version failed and the new one passed; the behavior is kept as an FudehandAppTests automated test.

## Real WebKit Probes

A temporary AppKit/WKWebView probe used the native canvas's ancestor-view coordinate scaling directly. After zooming to 25% and 50% and panning, JavaScript `innerWidth/innerHeight` and the WKWebView bounds both stayed 390×844. This confirms that web responsive breakpoints do not change with canvas zoom.

Another temporary WKWebView probe extracted the actual Escape injection script and sent, in order, a plain Escape, preventDefault, stopPropagation, Escape with a dialog open, and a plain Escape; the native bridge received only two exits. The probe loaded in-memory HTML and is not described as end-to-end acceptance of the examples.

## Delivery Scope

Standards and Spec independently reviewed the migration commits after base `a75250e`; Standards passed the first review, and the viewpoint-reset issue found by Spec was fixed in `ab16d75` with an added automated test. Both incremental re-reviews were PASS, with no unresolved valid findings in the end.

This repository has no remote; no PR, CI, or deployment is created. The existing localization changes remain uncommitted, and this migration is committed separately to `codex/native-macos`. The App is a local build that depends on the local source and Node/pnpm; it is not Developer ID signed or notarized, and no standalone distribution independent of the source is provided.

Keeping the web examples means WebKit processes and example dev-server overhead remain. No memory/CPU comparison on comparable workloads was done this time, and no specific performance improvement is promised.
