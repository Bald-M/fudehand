# 13. An installed App carries its Node tools and uses the Mac's Node.js

Date: 2026-11-21

## Status

Accepted

## Context

The MCP server (`scripts/mcp-server.mjs`) and the chat panel's Agent harness (`scripts/agent-chat.mjs`) are Node programs. Until now the App found them only through the source checkout it was built from (`workspace.json`, `--root`, or the working directory), and found Node and the agents' CLIs through the PATH recorded at build time. An App installed from a disk image on another Mac has none of these, so the MCP Connectors window could not connect anything and reported every existing registration as "another directory" (#236).

`scripts/fudehand-tools.mjs` must stay the only tool implementation (ADR 0003, 0006), so the MCP server cannot be rewritten in Swift.

## Decision

- The build copies the scripts the MCP server and the Agent harness run, `styles/`, `package.json`, and a flat production `node_modules` (a hoisted `pnpm install --prod` from the lockfile) into `Contents/Resources/Tools`, with a `build-id` unique to each build.
- A source build still uses its checkout first. Without one, the App copies `Tools` to `~/Library/Application Support/fudehand/tools` at launch, replacing it only when `build-id` differs, and uses that copy. Agent registrations therefore point at a path that does not change when the App is moved, updated, run from the disk image, or translocated by Gatekeeper.
- Node.js is not bundled (it would add roughly 100 MB). The App looks for Node.js 22.12 or later, and for the agents' CLIs, on the recorded PATH, the login shell's PATH, the inherited PATH, and the usual install locations, and registers the absolute path of the Node it found. Without a supported Node the window says what to install instead of only disabling *Connect*.
- A registration is connected only when it runs this App's script and its absolute command still exists; otherwise it can be re-pointed with *Update* (or `settings_set_connector` with `connected: true`).
- `pnpm package:native` builds a distributable App (no `workspace.json`) and `dist/Fudehand-<version>.dmg`. Signing and notarization stay out of scope.

## Consequences

- Users of the disk image need Node.js 22.12 or later for the MCP connectors and the chat panel; the canvas and project files need nothing.
- The App grows by about 26 MB; the v0.0.5 disk image with the tools is about 14 MB.
- An nvm-managed Node is registered by its versioned path; removing that version shows the connection as needing *Update* rather than failing silently.
