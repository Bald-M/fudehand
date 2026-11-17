## 自动开发与交付

项目修改遵循 `/Users/zhangzihan/.codex/skills/automatic-dev-delivery/SKILL.md`。远端为 GitHub `Bald-M/ui-atlas`（默认分支 `main`），未配置 CI 与部署，以本地检查为准；在任务分支开发，推送后向 `main` 发起 PR。

## Agent skills

### Issue tracker

任务直接用 `gh issue` 在 GitHub Issues（`Bald-M/ui-atlas`）创建和跟踪，不在本地维护任务记录。

### 界面图鉴 MCP

本仓库提供 `ui-atlas` MCP server（`scripts/mcp-server.mjs`），可读写作品与画框，并在 App 运行时操作画布、截取画框。Codex 在 `~/.codex/config.toml` 中配置：

```toml
[mcp_servers.ui-atlas]
command = "node"
args = ["/path/to/ui-atlas/scripts/mcp-server.mjs"]
```

工具说明见 README 的“AI Agent 接入”，设计见 `docs/adr/0003-agent-mcp.md`。

### Domain docs

使用根目录 `GLOSSARY.md` 和 `docs/adr/`，见 `docs/agents/domain.md`。
