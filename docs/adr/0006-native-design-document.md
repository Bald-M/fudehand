# Canvas Switches to a Native Design Document

2026-11-17 (#46). ui-atlas changes from displaying web projects to a native design tool: the canvas shows ui-atlas's own design document (a tree of layers), rendered directly by the App with Core Animation; people and agents edit the same document, agents send edit commands through the control channel, and the App is the document's single owner. Designs are saved as versioned, public JSON project files (`.uiatlas`).

The web-project pipeline is removed along with it: `WKWebView` frames, the Node preview launcher and example servers, `catalog.json` and its two validators (Swift and Node), and the web projects in `examples/`. ADR 0004 (start example servers on demand) and 0005 (web projects open only in App frames) no longer apply and are kept only as historical records. The structure of ADR 0003 is kept: the MCP server and the chat panel harness still share `scripts/atlas-tools.mjs`, but the tools now forward design commands; document fields are validated in only one place, in Swift.

## Rejected Alternatives

- **Keep the web projects and have agents edit source code**: every web project would need a front-end project and resident Node/Vite/WebKit processes, every agent edit would go through compilation and hot updates, and layer-level selection and property editing would be impossible.
- **The Node side owns the document, and the App only renders**: the document would have two owners, and human and agent edits would need synchronization and conflict resolution.
- **Full redraws with Core Graphics, or a SwiftUI canvas**: the former cannot keep panning and zooming smooth with more than 100 layers; the latter would be disconnected from the existing AppKit canvas's input and viewport implementation.
- **Read and write the Figma format**: a non-goal for this phase; a custom JSON format is easier for agents to understand directly and for version control.

## Consequences

- App startup no longer starts any Node process; the harness starts only when the chat panel sends a message, and still depends on this checkout and Node (`workspace.json`).
- Earlier Issues based on web projects (#18, #20, #23, #36) need to be re-evaluated.
- Rendering capabilities are constrained by Core Animation: rotation, gradients, shadows, and vector paths are not supported in this phase.
