# Frame Console, Page Reading, and Basic Interaction (#21)

## Purpose

After an agent modifies web project source via MCP, it needs to confirm that the change took effect, that there are no runtime errors, and to operate the page to verify interactions. Previously it could only call `frame_snapshot` and judge by eye.

## Goals

- `frame_console`: read a frame's recent console logs and uncaught errors.
- `frame_read`: read a condensed text outline of the frame's page, with CSS selectors attached to interactive elements.
- `frame_interact`: click, fill values, and scroll by selector.

## Non-goals

Full browser automation (multiple tabs, network interception, uploads), remote control, replacing the web project's own tests, waiting for a reload before taking a screenshot (optional, not done this time).

## Approach

- **Console capture**: `PreviewFrameView` injects a script into the page world (at document start, main frame only) that wraps `console.log/info/warn/error/debug`, listens for `error` and `unhandledrejection`, and sends messages back to native code through the `atlasConsole` message channel. The native side accepts only messages from the main frame and the preview's origin, and stores them per frame in `FrameConsole` (AtlasCore; a ring buffer of at most 200 entries, each at most 2000 characters). Because records live on the native side, they survive page reloads; each time loading finishes, an entry from the `atlas` source saying "Page loaded" (页面已加载) is appended as a separator.
- **Reading and interaction**: `callAsyncJavaScript` in a separate `WKContentWorld` (page scripts cannot modify our functions), with a 10-second timeout. Reading outputs an indented outline of at most 20000 characters and marks truncation. Interaction: click dispatches pointer/mouse events in order and then calls `click()`; fill sets value directly in the isolated world (bypassing any property overrides by the page) and then dispatches `input` and `change` (compatible with React controlled components); scroll can scroll to an element or scroll the page by `deltaX/deltaY`.
- **Boundaries**: no new navigation capability. Clicks are refused when the target is inside a link (including SVG `<a>` and `<area>`) pointing to a non-preview origin; during an interaction and for 1 second afterwards, external links and new windows triggered by page scripts do not open the system browser.
- **Errors**: App not running keeps "App is not running" (界面图鉴未运行); a frame that has not loaded returns "Frame not loaded yet: <id>" (画框尚未加载：<id>); invalid selectors or missing elements return Chinese errors.

## Alternatives considered

- Store logs in a page JS global and fetch them on read: lost on page reload, which misses exactly the errors after a hot update; rejected.
- Use the agent's own browser to visit the preview URL: cannot get the actual state of the frame inside the App, and the agent may not have browser tools; this is precisely what #21 fills in.
