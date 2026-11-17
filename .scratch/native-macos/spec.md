# macOS Native UI Atlas

Status: complete

Confirmed by the user on 2026-11-06: a macOS desktop App, a SwiftUI native canvas shell, WebKit embedding the existing web examples; keep the Chinese UI.

- Keep web project search, switching, descriptions, and attribution; support disabled web projects, empty directories, and error states.
- Keep frames at their original CSS viewport size, title dragging, keyboard moves, background and scroll-wheel panning, mouse-anchored zoom, trackpad pinch, 100%, Fit All (适应全部), and frame focus.
- Keep single-frame interaction mode, a fixed exit control, Escape that respects web page dialogs, reload, and opening externally.
- Keep the system/light/dark themes, and save position, zoom, and viewport per project; restore the default layout; fall back on corrupted or version-mismatched data.
- The same catalog.json drives both the native and web entry points; the App manages the example servers itself, starts only the examples, and on quit or failure cleans up the processes it owns, without killing external programs holding the port.
- Deliver a double-clickable local .app and reproducible build/launch commands; allow choosing the project directory, with readable messages and retry on failure.
- Confirmed automated test boundaries: directory configuration, canvas geometry, layout restore, and the server entry point / process lifecycle; real UI acceptance covers loading, empty, failure, light and dark themes, and different window widths.
- Keep the existing uncommitted Chinese localization changes; no remote, so do not create a remote or publish.

## Plan and Acceptance

1. Port the testable core, verifying configuration, geometry, and storage through red-green tests one by one.
2. Implement the native canvas and WebKit, keeping the web pages' responsive breakpoints and interactions.
3. Integrate example process ownership, the SwiftUI workbench, and the .app build; run the native and existing checks.
4. Independent Standards and Spec reviews; fix valid findings and make a local commit containing only this task.

## Delivery Record

The native App, packaging, and server ownership management are done. 24 web tests and 7 Swift tests pass; the Release build and signature verification pass. Real UI acceptance and limitations are in `docs/native-verification.md`. Standards and Spec both ended with PASS; the existing Chinese localization changes remain uncommitted, and there is no remote publishing step.
