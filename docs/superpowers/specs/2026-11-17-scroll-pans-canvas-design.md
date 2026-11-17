# Scrolling Always Pans the Canvas (#15) Design

## Intent

Following Figma: scrolling anywhere on the canvas only pans the canvas, and the active frame no longer "swallows" the scroll.

## Rules

- Mouse wheel or trackpad scrolling without ⌥ (including momentum) always pans the canvas, including over the active frame.
- ⌥ + scroll that starts inside the active frame's content scrolls the web page, for viewing pages longer than the frame. A trackpad gesture locks its target at the start and keeps it until momentum ends; pressing or releasing ⌥ midway does not switch it. Mouse wheel scrolling (no phases) is decided event by event.
- ⌘ / ⌃ + scroll and pinch still zoom the canvas anchored at the pointer, taking priority over ⌥.
- Frame scroll bars were already hidden in #28; unchanged.

## Approach

- **⌥ + scroll (chosen)**: smallest change, does not alter the CSS viewport. The cost is having to remember the shortcut, and scrollable areas inside the web page also require ⌥.
- Frame height expands with content: changes the CSS viewport height, conflicting with the issue's non-goals.
- Manually resizing frames: needs new interaction and persistence, and also changes the viewport.

## Scope of changes

- `AtlasCore/ScrollRouting.swift`: `route` gains a `pageModifier` input; the result is `.page` only when `overActivePage && pageModifier`.
- `AtlasApp/CanvasView.swift`: pass `.option` in.
- `AtlasApp/WorkspaceView.swift`: add the "⌥ scroll web page" (⌥滚动网页) hint to the bottom bar for discoverability.
- Sync the scrolling rules in `docs/macos.md`; put light and dark screenshots in `docs/evidence/`.
