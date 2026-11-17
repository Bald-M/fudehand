## Automatic development and delivery

Project changes follow `/Users/zhangzihan/.codex/skills/automatic-dev-delivery/SKILL.md`. The remote is GitHub `Bald-M/ui-atlas` (default branch `main`). No CI or deployment is configured, so local checks are the gate; develop on a task branch, push, and open a PR against `main`.

## Agent skills

### Issue tracker

Create and track tasks directly in GitHub Issues (`Bald-M/ui-atlas`) with `gh issue`; do not keep task records locally.

### ui-atlas MCP

This repository provides the `ui-atlas` MCP server (`scripts/mcp-server.mjs`), which reads and edits the design document, controls the viewport, and takes screenshots while the App is running. Configure it for Codex in `~/.codex/config.toml`:

```toml
[mcp_servers.ui-atlas]
command = "node"
args = ["/path/to/ui-atlas/scripts/mcp-server.mjs"]
```

By default Codex asks for approval before each MCP tool call; for unattended runs, add `default_tools_approval_mode = "approve"` to that section. See "Working with AI agents" in [README.md](README.md) for the tools (Chinese version: [README.zh-CN.md](README.zh-CN.md)), and `docs/adr/0003-agent-mcp.md` for the design.

### Domain docs

Use the root `GLOSSARY.md` and `docs/adr/`; see `docs/agents/domain.md`.
