# Agent Tools

Fudehand is operated by Agents as much as by people. This document is the specification for the tools Agents use, shared by the MCP server and the chat panel's Agent harness. The decision behind it is [ADR 0007](adr/0007-agent-parity.md); the transport is described in [ADR 0003](adr/0003-agent-mcp.md) and [ADR 0006](adr/0006-native-design-document.md).

The words MUST, MUST NOT, and SHOULD are used as in RFC 2119.

## 1. Parity

1. Every feature a person can use in the App MUST be available as an Agent tool. This includes the design document, the project file, the canvas view, the prototype window, the launch window, fonts, the chat panel and its conversations, and every setting (UI language, appearance, model providers, API keys, MCP connectors).
2. A feature is the outcome a person can choose to produce, not the gesture used to produce it. Pointer feedback (hover highlights, drag previews, snapping guides, handles) is not a feature: the tool states the outcome directly, for example exact coordinates instead of a snapped drag.
3. A pull request that adds or changes a feature MUST add or change its tool in the same pull request, together with the tests in [§6](#6-tests) and the [coverage table](#7-coverage). A feature without a tool is not done.
4. An exception MUST be justified in the pull request and recorded in the coverage table with its reason. "Only useful to people" is not a reason.

## 2. One path

1. A tool is defined once, in `scripts/fudehand-tools.mjs`. The MCP server and the Agent harness MUST NOT define their own copies. The only tools outside that file are those that act on the harness's own reply (the question card's `ask_user`), and they MUST be listed in the coverage table.
2. A tool MUST forward to the App over the control channel: a command in `FudehandCore/ControlProtocol.swift`, dispatched in `FudehandApp/ControlCommands.swift`.
3. The App MUST carry out a command by calling the same store method that the UI calls for that feature. Logic that only Agents reach is not allowed; if the UI method needs a parameter the UI gets from a dialog, give the method that parameter and have the UI pass it.
4. Field validation happens once, in Swift (`DesignJSON` for layers). The Node side MUST NOT validate fields; it only reads `image.path` into data and resolves relative file paths, as it does today.

## 3. Behavior

1. **No modal UI.** A tool MUST NOT open a dialog, sheet, file panel, or alert, or wait for a person. Whatever the UI asks in a dialog becomes an argument: a file path instead of an open or save panel, `discard: true` instead of a "discard unsaved changes?" alert. Without the argument the tool fails with a message that names it.
2. **Errors, not silence.** A tool that cannot do what was asked MUST return an error that says why, in English, without localizing it. It MUST NOT quietly do part of the work or something else.
3. **Undo.** A tool that changes the design document MUST be exactly one step in the shared undo history, named `Agent: <action>` (for example `Agent: Update Layer`). Settings and other state outside the document are not undoable: their tools MUST return the previous value so an Agent can restore it.
4. **Readable state.** Anything the UI shows that a person uses to decide what to do next MUST be readable by a tool: the document and selection, the viewport, unsaved changes, recent files and templates, fonts, the current settings, connector status, and conversations.
5. **Results.** A tool that changes something SHOULD return the changed object or the new state, so an Agent does not need a second call to check it.
6. **Live updates.** A change made by a tool MUST appear in the UI at once, the same as if a person had made it.

## 4. Settings and secrets

1. Settings tools MUST write through the same storage the settings UI uses (UserDefaults, the Keychain, the connector code), so a change made by either one shows in the other.
2. An API key MUST be write-only. A tool may set or delete a key; any read returns only whether a key is saved and the masked hint the UI shows (first and last 4 characters). Tool results, errors, and logs MUST NOT contain a key.
3. A setting that only takes effect later (for example a model change that applies to the next message, or menu items that change after a restart) MUST say so in its result.
4. A tool that changes files outside Fudehand, such as registering the MCP server in another Agent's configuration, MUST report each file or command it changed.

## 5. Naming and descriptions

| Namespace | Covers |
|---|---|
| `design_*` | The design document, layers, selection, undo, the project file, fonts |
| `canvas_*` | The viewport and the canvas tool |
| `prototype_*` | The prototype window |
| `app_*` | Windows, the launch window, recent files, templates |
| `settings_*` | UI language, appearance, model providers, API keys, MCP connectors |
| `chat_*` | Conversations in the chat panel |

1. Tool names are `snake_case` with one of these prefixes. The control-channel command is the same name without the prefix (`design_get_node` → `get_node`). A new namespace MUST be added to this table first.
2. Before adding a tool, check whether the behavior is a variant of an existing one; if so, add an argument instead (for example a scale argument rather than separate zoom-in and zoom-out tools).
3. Descriptions and argument descriptions are in English, say what the tool changes and what it returns, and use the terms in `GLOSSARY.md`.
4. A tool MUST NOT stop, delete, or reconfigure the conversation that is calling it; it returns an error instead.

## 6. Tests

A new or changed tool needs:

- `tests/control-tools.test.ts`: the tool is listed and forwards its command and arguments unchanged.
- `native/Tests/FudehandCoreTests/ControlProtocolTests.swift`: the command parses, and bad arguments are rejected.
- `native/Tests/FudehandAppTests/StoreTests.swift` (or the test file of the feature): `handleControl` produces the same result as the UI path, including the undo step or the returned previous value.

## 7. Coverage

Every feature and the tool that covers it. When a pull request changes this, update the table in the same pull request. Missing tools are tracked in GitHub Issues.

### Design document and project file

| Feature | Tool |
|---|---|
| Read the document overview, the layer tree, one layer | `design_get_state`, `design_get_document`, `design_get_node` |
| Create layers (frame, rectangle, ellipse, text, image, group), insert an image | `design_create_node` |
| Edit layer properties: position, size, fill, stroke, corner radius, opacity, text, auto layout, image, clip content, interaction, scrolling, fixed position when scrolling, hover and pressed states | `design_update_node` |
| Rename, show/hide, lock a layer | `design_update_node` |
| Reorder or reparent layers (bring forward, send to back, drag in the layers panel) | `design_move_node` |
| Delete layers | `design_delete_nodes` |
| Select layers | `design_select` |
| Undo, redo | `design_undo`, `design_redo` |
| New, open, save, save as | `design_new_document`, `design_open_document`, `design_save_document` |
| Snapshot a layer as PNG | `design_snapshot` |
| List fonts, import a font | `design_list_fonts`, `design_import_font` |

### Canvas and windows

| Feature | Tool |
|---|---|
| Zoom, zoom in/out, actual size | `canvas_zoom` |
| Fit all | `canvas_fit_all` |
| Zoom to a layer | `canvas_focus_node` |
| Zoom to a multi-layer selection | Missing |
| Choose the canvas tool (move, hand, frame, rectangle, ellipse, text) | Missing |
| Show or hide the inspector, switch its tab | Missing |
| Expand or collapse layers in the layers panel | Missing |
| Play the prototype, play from the start, close the prototype window | Missing |
| Show the launch window | Missing |
| List, open, remove, clear recent files | Missing |
| List templates, create a document from a template | Missing |

### Settings

| Feature | Tool |
|---|---|
| UI language | Missing |
| Appearance (System, Light, Dark) | Missing |
| Model provider settings: base URL, model, default model; list models | Missing |
| Set or delete an API key; test the connection | Missing |
| MCP connector status, connect, disconnect | Missing |

### Chat panel

| Feature | Tool |
|---|---|
| List conversations, open, switch, close a conversation tab, start a new one, delete one | Missing |
| Send a message (with context tags, `/plan`, `/goal`), stop, regenerate, edit the last message, answer a question card, `/compact` | Missing |
| Ask the user a question (question card) | `ask_user`, Agent harness only |
