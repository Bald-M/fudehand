# Agent Integration (MCP, Control Channel, and Chat Panel) Design

Tracking: #2; sub-issues: #3, #4, #5, #6, #9, #7. Date: 2026-11-17. Status: approved.

## Intent

Let AI agents read and write web projects and frames without hand-editing `catalog.json`, and, while the App is running, operate the canvas and capture frame screenshots. There are two kinds of agents: external Claude Code / Codex (via MCP), and the Node Agent harness behind the in-App chat panel (calling DeepSeek, Claude, OpenAI). Both share the same tool implementation.

## Goals / Non-goals

- Goals and acceptance are defined by each sub-issue.
- Non-goals: remote access; changing the catalog format; implementing MCP in Swift or calling model APIs directly from Swift; third-party Swift packages; a browser shell; DOM manipulation inside frames.
- Anti-goals: a third copy of catalog validation; API keys ending up in the repository, logs, UserDefaults, or process arguments.

## Trade-offs

- **Chosen: Node bridge + Unix socket control channel.** The MCP server and the harness are both Node and reuse `servicesFromCatalog`; the App exposes only one local socket with mode 0600.
- Rejected: an MCP server built into Swift (requires writing the protocol ourselves or adding a third-party package, plus another copy of validation); an HTTP control port (listens on a network address and needs extra authentication).
- Delivery: 6 PRs in dependency order (#3 → #4 → #5 → #6 → #9 → #7), each independently revertible.

## Structure

```
Claude Code / Codex ─stdio─▶ scripts/mcp-server.mjs ─┐
App chat panel ─stdio(JSON lines)─▶ scripts/agent-chat.mjs ─┤
                                                      ▼
                                   scripts/atlas-tools.mjs (the only tool implementation)
                                   ├─ Web project data layer: reads/writes catalog.json (servicesFromCatalog validation + atomic write)
                                   └─ Canvas control layer: scripts/control-client.mjs ─Unix socket─▶ App (AtlasStore)
```

- **Tool definitions**: each tool is `{ name, description, inputSchema(JSON Schema), run(args, ctx) }` and returns MCP-style `content` (`text` / `image`). The MCP server uses the SDK's low-level `Server` to expose the JSON Schema directly, and the harness passes the same schema to the model API, so no zod layer is introduced.
- **Writes**: read → modify an in-memory copy → `servicesFromCatalog(next, root)` → temp file in the same directory + rename, 2-space indentation, trailing newline. On failure, return the launcher's original Chinese error and leave the file unchanged. When launch arguments change, note that the preview needs a restart.
- **Control channel**: `~/Library/Application Support/界面图鉴/control.sock`, mode 0600; stale sockets are cleaned up on launch and the socket is deleted on exit. The path can be overridden with the environment variable `UI_ATLAS_CONTROL_SOCKET` (for tests). The protocol is newline-delimited JSON: request `{"id":1,"command":"focus_frame","args":{"frame":"mobile"}}`, response `{"id":1,"ok":true,"result":{…}}` or `{"id":1,"ok":false,"error":"…"}`. Encoding/decoding and argument validation live in `AtlasCore`; the socket and dispatch live in `AtlasApp` (calling `AtlasStore` on the main thread). `frame_snapshot` uses `WKWebView.takeSnapshot` and returns a base64 PNG. When the connection fails, tools return "App is not running" (界面图鉴未运行).
- **Chat panel**: the App launches `agent-chat.mjs` when needed, passing provider, model, baseUrl, and key through environment variables (the key comes from the Keychain). stdin/stdout carry JSON lines: the App sends `user` (with the selected layers as `context`) / `stop` / `load` (replaces the history); the harness sends `assistant_delta`, `assistant`, `tool_call`, `tool_result`, `error`, `done`. Providers: OpenAI-compatible (DeepSeek, OpenAI; `baseUrl` and model are configurable) and Anthropic Messages. Stop aborts the current request, and no further tool calls are executed afterwards; the harness exits on stdin EOF.

## Verification (decided)

- Model APIs are verified with local fake servers (both OpenAI-compatible and Anthropic formats) for multi-turn conversation, tool calls, and errors; acceptance with real keys is left to the user, and the unchecked items are noted in the PR.
- Canvas control, screenshots, and the chat panel are captured in the real App in light and dark appearances and stored in `docs/evidence/`.

## Left to the implementer

Tool result wording, panel layout details, and the exact naming of harness message fields, favoring whatever is simple and testable.
