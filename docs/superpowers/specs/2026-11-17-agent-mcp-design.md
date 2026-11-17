# Agent 接入（MCP、控制通道与对话面板）设计

跟踪：#2；子 Issue：#3、#4、#5、#6、#9、#7。日期：2026-11-17。状态：已批准。

## 意图

让 AI Agent 不必手改 `catalog.json` 就能读写作品与画框，并在 App 运行时操作画布、拿到画框截图。Agent 有两类：外部的 Claude Code / Codex（经 MCP），以及 App 内对话面板背后的 Node Agent harness（调用 DeepSeek、Claude、OpenAI）。两类共用同一份工具实现。

## 目标 / 非目标

- 目标与验收以各子 Issue 为准。
- 非目标：远程访问；修改 catalog 格式；Swift 内实现 MCP 或直接调用模型 API；第三方 Swift 包；浏览器壳；画框内 DOM 操作。
- 反目标：出现第三份 catalog 校验；API key 进入仓库、日志、UserDefaults 或进程参数。

## 方案取舍

- **选定：Node 桥接 + Unix socket 控制通道。** MCP server 与 harness 都是 Node，复用 `servicesFromCatalog`；App 只暴露一个 0600 的本地 socket。
- 否决：Swift 内置 MCP（需自写协议或引入第三方包，且要再写一份校验）；HTTP 控制端口（会监听网络地址，需要额外鉴权）。
- 交付：按依赖顺序 6 个 PR（#3 → #4 → #5 → #6 → #9 → #7），每个独立可回滚。

## 结构

```
Claude Code / Codex ─stdio─▶ scripts/mcp-server.mjs ─┐
App 对话面板 ─stdio(JSON 行)─▶ scripts/agent-chat.mjs ─┤
                                                      ▼
                                   scripts/atlas-tools.mjs（唯一工具实现）
                                   ├─ 作品数据层：读写 catalog.json（servicesFromCatalog 校验 + 原子写）
                                   └─ 画布控制层：scripts/control-client.mjs ─Unix socket─▶ App（AtlasStore）
```

- **工具定义**：每个工具是 `{ name, description, inputSchema(JSON Schema), run(args, ctx) }`，返回 MCP 风格的 `content`（`text` / `image`）。MCP server 用 SDK 的低层 `Server` 直接暴露 JSON Schema，harness 把同一份 schema 转给模型 API，因此不引入 zod 层定义。
- **写入**：读取 → 改内存副本 → `servicesFromCatalog(next, root)` → 同目录临时文件 + rename，2 空格缩进、末尾换行。失败返回 launcher 原文中文错误，文件不变。改了启动参数时提示需要重启预览。
- **控制通道**：`~/Library/Application Support/界面图鉴/control.sock`，0600，启动时清理残留、退出时删除。可用环境变量 `UI_ATLAS_CONTROL_SOCKET` 覆盖路径（测试用）。协议为行分隔 JSON：请求 `{"id":1,"command":"focus_frame","args":{"frame":"mobile"}}`，响应 `{"id":1,"ok":true,"result":{…}}` 或 `{"id":1,"ok":false,"error":"…"}`。编解码与参数校验在 `AtlasCore`，socket 与分发在 `AtlasApp`（主线程调用 `AtlasStore`）。`frame_snapshot` 用 `WKWebView.takeSnapshot`，返回 base64 PNG。连接失败时工具返回“界面图鉴未运行”。
- **对话面板**：App 在需要时启动 `agent-chat.mjs`，经环境变量传入提供方、模型、baseUrl 和 key（key 来自钥匙串）。stdin/stdout 为 JSON 行：App 发送 `user` / `stop` / `clear`；harness 发送 `assistant`、`tool_call`、`tool_result`、`error`、`done`。提供方：OpenAI 兼容（DeepSeek、OpenAI，`baseUrl` 与模型可配）与 Anthropic Messages。停止会中止当前请求，之后不再执行工具调用；stdin EOF 时 harness 退出。

## 验证方式（已确定）

- 模型 API 用本地假服务（OpenAI 兼容与 Anthropic 两种格式）验证多轮对话、工具调用和报错；真实 key 的验收留给使用者，PR 中注明未勾选项。
- 画布控制、截图与对话面板在真实 App 的浅色、深色外观下截图，存入 `docs/evidence/`。

## 留给实现者

工具结果文案、面板布局细节、harness 消息字段的具体命名，以简单可测为准。
