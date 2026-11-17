# Agents Connect Through a Node MCP Server and a Local Control Channel

> Partially superseded by [ADR 0006](0006-native-design-document.md): the structure of the MCP server, the control channel, and the chat panel is kept, while the web-project data layer (`catalog.json`) and the frame tools were removed, and the tools now edit the design document.

2026-11-17. So that AI agents can organize web projects and frames without hand-editing `catalog.json`, and can operate the canvas and take frame screenshots while the App is running (#2), the integration has three parts:

- **MCP server** (`scripts/mcp-server.mjs`): a Node stdio process that external agents such as Claude Code and Codex start on demand. The web-project data layer reads and writes `catalog.json` directly; before writing it validates with the launcher's `servicesFromCatalog`, then atomically replaces the file via a temporary file and rename. If validation fails, the file is not changed.
- **Control channel**: while the App runs it listens on a Unix domain socket at `~/Library/Application Support/ui-atlas/control.sock` (permissions 0600, directory 0700, peer uid checked), with a newline-delimited JSON protocol. The MCP canvas tools are forwarded to the App through `scripts/control-client.mjs`, and commands are dispatched to `AtlasStore` on the main thread. Protocol encoding and decoding live in `AtlasCore` and do not depend on AppKit.
- **Chat panel and Agent harness**: the in-App chat panel starts `scripts/agent-chat.mjs` and exchanges JSON lines over stdin/stdout. The harness runs the conversation loop and tool calls, and calls DeepSeek (OpenAI-compatible Chat Completions), OpenAI (the Responses API, the only one Codex-series models support), or the Anthropic Messages API. The API key is stored in the Keychain and passed to the harness only through an environment variable.

All tools have a single implementation, `scripts/atlas-tools.mjs`, shared by the MCP server and the harness. Catalog validation still exists only in two copies, Node and Swift (see `tests/fixtures/catalog-conformance.json`); no third copy is added.

## Rejected Alternatives

- **Implement the MCP server in Swift**: this would mean either hand-writing the MCP protocol or adding a third-party Swift package, which violates the "no third-party Swift packages" convention; writing the catalog would also require reusing or rewriting Node's validation and atomic writes in Swift.
- **HTTP control port**: it would listen on a network address, and even bound only to loopback it would need extra authentication to keep other users on the same machine or web pages out. A Unix socket can be restricted to the current user with file permissions and the peer uid alone.
- **Call the model APIs directly from Swift**: this would require a second tool-calling loop and set of tools in Swift that could not be shared with MCP; with this in Node, the App only handles the UI, processes, and the Keychain.

## Consequences

- Both the MCP server and the harness depend on this checkout and on the Node installation, consistent with how the App launches previews.
- The canvas tools are available only while the App is running; otherwise they return "ui-atlas is not running" (ui-atlas 未运行). The App reads `catalog.json` only when opening a project, so results of write tools note that they take effect after restarting the preview.
- Remote access is not supported.
- Frame page layer (#21): `frame_console`, `frame_read`, and `frame_interact` let an agent confirm there are no runtime errors after modifying a web project and verify interactions. Console output is collected by a script the frame injects into the page world, and records are kept in the App (200 per frame, surviving reloads); reading and interaction run in an isolated script world. Capabilities are limited to basic clicking, filling values, scrolling, and reading visible content, with no navigation, multiple tabs, network interception, or uploads; clicking a link that points to another site (including SVG links and image map areas) or that opens in a new window is rejected; off-site navigations and new windows triggered by page scripts are cancelled by the frame's navigation policy, and the system browser is never opened. Console content comes from the page itself and the page can forge records, so the agent should treat it as page data rather than the App's judgment. Previews open only in App frames (see [0005](0005-preview-only-in-app.md)), and accessing a preview URL directly from a browser returns 403.
