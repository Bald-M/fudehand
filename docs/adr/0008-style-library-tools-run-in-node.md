# Style Library Tools Run in Node, Outside the Control Channel

2026-11-18 (#115). The Agent gets a style library (`styles/`): reference files, adapted from VoltAgent/awesome-design-md, that describe a named style in terms of the layer model. Two tools read it, `style_list` and `style_read`, defined in `scripts/style-library.mjs` and exported with the design tools from `scripts/fudehand-tools.mjs`, so the chat panel's Agent harness and the MCP server share them as ADR 0003 requires.

Unlike every other tool, they do not go through the control channel: they read files in this checkout from the Node process and never touch the design document. ADR 0006 makes the App the only owner of the design document; reference material that is not part of the document does not need the App, and the tools work when it is not running. `style_read` accepts only a name from the list (lowercase letters, digits, hyphens), so it cannot read anything outside `styles/`.

This is the one exception to rule 2.2 in [Agent tools](../agent-tools.md) ([ADR 0007](0007-agent-parity.md)) that a tool forwards to the App: the style library is not an App feature a person uses, only reference material for the Agent, so there is no store method for the tool to share with the UI. The tools use their own `style_*` namespace and are listed in that document's coverage table.

## Rejected Alternatives

- **Bundle the styles in the App and serve them over the control channel**: adds a protocol command and Swift code for read-only text that the App never uses itself, and ties the tools to the App running.
- **Put the styles in the system prompt or the MCP instructions**: the upstream files total about 2.4 MB and even the rewritten ones are up to 6,000 characters each; MCP clients cut instructions off at about 2,048 characters.
- **Make the styles part of the design document (variables or tokens)**: out of scope; a style is a reference for the Agent, not a document feature.

## Consequences

- The tools depend on this checkout, like the rest of the harness (`workspace.json`); a style added to `styles/` is available without rebuilding the App.
- A future tool that reads only reference files can follow the same pattern; anything that reads or edits the design document still goes through the control channel.
