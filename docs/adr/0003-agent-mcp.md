# Agent 经 Node MCP 与本地控制通道接入

2026-11-17。为了让 AI Agent 不必手改 `catalog.json` 就能整理作品与画框，并在 App 运行时操作画布、获取画框截图（#2），接入分为三部分：

- **MCP server**（`scripts/mcp-server.mjs`）：Node stdio 进程，由 Claude Code、Codex 等外部 Agent 按需启动。作品数据层直接读写 `catalog.json`，写入前调用 launcher 的 `servicesFromCatalog` 校验，再经临时文件与 rename 原子替换；校验失败时不改文件。
- **控制通道**：App 运行时在 `~/Library/Application Support/界面图鉴/control.sock` 监听 Unix domain socket（权限 0600、目录 0700、校验对端 uid），协议为行分隔 JSON。MCP 的画布工具经 `scripts/control-client.mjs` 转发到 App，命令在主线程分发到 `AtlasStore`。协议编解码在 `AtlasCore`，不依赖 AppKit。
- **对话面板与 Agent harness**：App 内的对话面板启动 `scripts/agent-chat.mjs`，经 stdin/stdout 交换 JSON 行。harness 负责对话循环和工具调用，调用 DeepSeek（OpenAI 兼容的 Chat Completions）、OpenAI（Responses API，Codex 系列模型只支持它）或 Anthropic Messages API。API key 保存在钥匙串，只经环境变量传给 harness。

所有工具只有一份实现：`scripts/atlas-tools.mjs`，被 MCP server 和 harness 共用。catalog 校验仍只有 Node 与 Swift 两份（见 `tests/fixtures/catalog-conformance.json`），不新增第三份。

## 否决的方案

- **在 Swift 内实现 MCP server**：要么手写 MCP 协议，要么引入第三方 Swift 包，违背“不依赖第三方 Swift 包”的约定；写入 catalog 时还需要在 Swift 内复用或重写 Node 的校验与原子写入。
- **HTTP 控制端口**：会监听网络地址，即使只绑定回环也需要额外鉴权防止同机其他用户或网页访问。Unix socket 借助文件权限和对端 uid 即可只对当前用户开放。
- **Swift 直接调用模型 API**：需要在 Swift 内再实现一套工具调用循环和工具，无法与 MCP 共用；放在 Node 端后，App 只负责界面、进程和钥匙串。

## 影响

- MCP server 和 harness 都依赖本检出目录与 Node 安装，与 App 的预览启动方式一致。
- 画布工具只在 App 运行时可用，否则返回“界面图鉴未运行”。App 只在打开项目时读取 `catalog.json`，写入工具的结果会提示重启预览后生效。
- 不支持远程访问。
- 画框页面层（#21）：`frame_console`、`frame_read`、`frame_interact` 让 Agent 修改作品后确认没有运行时错误并验证交互。控制台由画框在页面世界注入的脚本收集，记录保存在 App 内（每个画框 200 条，重载后仍在）；读取和交互在独立的脚本世界执行。能力只限于基础点击、填值、滚动和读取可见内容，不提供导航、多标签、网络拦截或上传；点击指向其他站点或在新窗口打开的链接会被拒绝，页面脚本触发的跨源导航仍由画框的导航策略取消。需要完整浏览器自动化时，Agent 用自己的浏览器工具访问预览 URL。
