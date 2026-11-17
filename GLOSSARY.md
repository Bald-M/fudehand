# 界面图鉴

在同一张画布中比较和体验不同尺寸的界面习作。

## 术语

**作品**：拥有共同设计目标、介绍与出处的一组界面习作。

**画框**：画布上展示作品某个页面的固定尺寸视口。
_避免_：设备模拟器

**画布**：用于摆放、比较和聚焦画框的可平移、缩放工作空间。

**活动画框**：唯一选中且已加载的画框，指针与键盘输入直接交给其网页。

**默认布局**：作品指定的画框初始位置。恢复默认布局会撤销用户保存的位置和视角。

**MCP server**：供外部 AI Agent（Claude Code、Codex 等）按需启动的本地工具进程（`scripts/mcp-server.mjs`），提供作品数据层与画布控制层工具。

**控制通道**：App 运行时只对当前用户开放的本地 Unix socket，外部进程经它读取画布状态、操作画布和截取画框。
_避免_：控制端口、API 服务

**对话面板**：App 内与 AI 对话的侧边面板，AI 通过与 MCP server 相同的工具整理作品和操作画布。

**Agent harness**：对话面板背后的 Node 子进程（`scripts/agent-chat.mjs`），负责对话循环、调用模型 API 和执行工具。

**模型提供方**：对话面板可选的模型 API 来源：DeepSeek、Anthropic Claude、OpenAI。DeepSeek 使用 OpenAI 兼容接口，OpenAI 使用 Responses API。
