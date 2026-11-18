# Every App Feature Is an Agent Tool

2026-11-19. Fudehand's core purpose is to let Agents operate the App. So far tools were added case by case, and features such as templates, recent files, the prototype window, the UI language, model settings, MCP connectors, and the chat panel's conversations could only be reached by a person. From now on, **every feature a person can use in the App, settings included, also exists as an Agent tool**, and a feature is not done until its tool ships with it. The rules, the tool namespaces, and the current coverage are in [Agent tools](../agent-tools.md).

The structure from [ADR 0003](0003-agent-mcp.md) and [ADR 0006](0006-native-design-document.md) is kept: one tool implementation in `scripts/fudehand-tools.mjs`, shared by the MCP server and the Agent harness, forwarded over the control channel to the App, which dispatches it to the same store methods the UI calls.

## Rejected Alternatives

- **Expose only design-document editing, and keep settings and the chat panel human-only**: an Agent could build a design but not set the App up for it (fonts, language, models, connectors), so a person would still have to sit in the loop for routine work. Settings are part of operating the App.
- **Let Agents drive the UI through accessibility or synthetic pointer events**: it depends on layout and localization, cannot report structured results or errors, and breaks whenever the UI changes.
- **A separate scripting interface (AppleScript, App Intents, URL scheme) per feature**: a second set of entry points that would drift from the MCP tools. App Intents also need Xcode's metadata extraction, which the Command Line Tools build does not have.

## Consequences

- A pull request that adds or changes a user-facing feature also adds or changes its tool, its tests, and the coverage table in `docs/agent-tools.md`. Features that predate this decision are listed there as missing until their tools exist.
- Settings tools change state outside the design document (UserDefaults, the Keychain, other Agents' configuration files). They are not part of the document's undo history.
- API keys can be set by a tool but never read back; reads return only the masked hint the UI shows.
- The number of tools grows. Tools are grouped by namespace so a client can tell them apart, and new behavior extends an existing tool with an argument when it is a variant of what that tool already does.
