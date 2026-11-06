# 界面图鉴 · macOS

现在默认使用 **SwiftUI + AppKit 原生 macOS App**。作品侧栏、工具栏、画布和偏好由 Swift 实现，现有 Vue/React 案例通过系统 WebKit 展示。

```bash
pnpm install
pnpm dev
```

`pnpm dev` 构建并打开 App，App 自动启动案例服务，退出时清理服务。需要 macOS 14+、Swift 6+（Xcode Command Line Tools 即可）、Node.js 22.12+ 和 pnpm 11.7.0。

- 发布优化构建：`pnpm build:native`，然后双击 `dist/界面图鉴.app`。
- 原生测试：`pnpm test:native`；现有网页案例检查：`pnpm check`。
- 浏览器兼容入口：`pnpm dev:web`。

完整操作、构建和边界说明见 [macOS 使用说明](docs/macos.md)。App 使用本地源码目录和 Node/pnpm，当前是本机构建，不是脱离源码的独立分发包。网页案例仍有 WebKit 渲染开销。

<details>
<summary>浏览器兼容版与案例接入文档</summary>

以下原有文档中的 `pnpm dev` 请改用 `pnpm dev:web`。目录配置与案例接入方式继续共用。

# UI Atlas

一个放在本机的 UI 学习画布。把喜欢的设计复刻为可交互的页面，或接入现成前端源码，在同一张画布里比较移动、网页和 PC 界面。

画布使用 **Vue 3 + TypeScript + Vite + 原生 CSS**。案例各自运行在独立的 iframe 中，保留自己的框架、路由、依赖和样式；Node 脚本只负责启动和清理开发服务。

## 开始使用

需要 Node.js **22.12+** 和 pnpm **11.7.0**。进程组清理按本机 macOS 使用场景实现。

```bash
pnpm install
pnpm dev
```

看到“UI Atlas 已就绪”后打开 <http://127.0.0.1:4400/>。

| 服务 | 地址 | 内容 |
| --- | --- | --- |
| UI Atlas | `http://127.0.0.1:4400/` | 作品索引与画布 |
| Still | `http://127.0.0.1:4401/` | Vue 原创三端日常计划工具 |
| Form & Field | `http://127.0.0.1:4402/` | React 原创灵感收集器 |

根命令会同时启动画布和 `enabled: true` 的全部案例。按 **Ctrl+C** 统一停止；启动失败或任一服务意外退出时，也会清理本次启动的其它服务。暂时不用的作品可在配置中停用，再重启根命令。

## 如何操作

- 拖动空白、按住 Space 拖动，或使用滚轮平移画布。
- Ctrl/Cmd + 滚轮以鼠标所在位置缩放；工具栏也提供缩放、100% 与适应全部。
- 拖动画框标题栏调整位置，使用画框聚焦操作查看细节。
- 默认处于浏览模式；进入某个画框的交互模式后，可以正常点击、输入及滚动案例。
- 工具栏的退出按钮始终可用。内置案例也可以按 Esc 返回画布；已有弹窗可先处理 Esc，再返回画布。
- “恢复默认布局”会清除该作品已保存的位置与视角。

手机、网页、PC 是不同尺寸的 **CSS 视口**，不模拟设备系统、像素密度或原生能力。主要在电脑浏览器使用，窄屏可收起作品侧栏。

## 目录与配置

```text
apps/atlas/                 Vue 画布外壳
examples/still/             Vue 三端案例
examples/form/              React 案例
packages/preview-bridge/    可选的 Esc 通信桥
catalog.json               作品资料、画框与启动配置的权威来源
scripts/                   本地进程启动与清理
```

新增案例时，把源码放到 `examples/<作品名>/`，在 `catalog.json` 的 `projects` 中加入一项：

```json
{
  "id": "my-study",
  "title": "My Study",
  "subtitle": "一句简短介绍",
  "description": "记录复刻目标、值得学习的设计点。",
  "author": "原作者姓名",
  "sourceUrl": "https://example.com/original-design",
  "framework": "Vue 3",
  "tags": ["移动端", "交互设计"],
  "enabled": true,
  "layoutVersion": 1,
  "preview": {
    "cwd": "examples/my-study",
    "command": ["pnpm", "dev"],
    "port": 4403,
    "baseUrl": "http://127.0.0.1:4403/"
  },
  "frames": [
    {
      "id": "mobile-home",
      "title": "首页 / 移动端",
      "platform": "mobile",
      "path": "/?view=mobile",
      "width": 390,
      "height": 844,
      "x": 0,
      "y": 0
    }
  ]
}
```

- `id` 是稳定标识，作品之间不重复，使用小写字母、数字或连字符；同一作品的画框 ID 也须唯一。
- `sourceUrl` 是原作出处，可使用 HTTP/HTTPS 地址；原创演示没有外部出处时填 `null`。不要把原作链接填进本地预览地址。
- `enabled` 控制是否随根命令启动。所有作品的端口仍须独立，包括暂时停用的作品。
- `preview.cwd` 是相对仓库根目录的现存目录；`command` 是直接执行的参数数组，不支持 shell 管道、`&&` 或环境变量展开。
- `port` 是**预期端口声明**，不会自动改变任意工具链的启动参数。请同步设置案例自己的命令，使用固定端口和严格端口检查。
- `baseUrl` 使用与端口一致的本机 HTTP 地址。可使用 `127.0.0.1`、`localhost` 或 `::1`，但日常固定使用 `127.0.0.1`，以保持浏览器保存数据和 Esc 桥的来源一致。
- 画框 `width/height` 是正数，`x/y` 是画布中的有限坐标。`platform` 使用 `mobile`、`web` 或 `desktop`。
- 修改案例目录、命令、端口、启用状态或画框配置后，停止并重启 `pnpm dev`，再刷新画布。

画框路径使用 `new URL(path, baseUrl)` 解析：当基础地址是 `http://127.0.0.1:4403/demo/` 时，`login` 指向 `/demo/login`，`/login` 指向站点根目录的 `/login`。支持查询参数与 hash 路由；画框应指向该作品自己的本地服务。多个画框共享一个案例进程。

### 添加 Vue 或 React 案例

复制对应的内置案例到新目录，修改包名、页面内容和固定端口，再增加配置项。常用端口设置如下：

```json
{
  "scripts": {
    "dev": "vite --host 127.0.0.1 --port 4403 --strictPort",
    "build": "vite build"
  }
}
```

新目录由 pnpm workspace 管理。改完依赖后在根目录执行 `pnpm install`。同一作品可用不同路径或查询参数实现多个页面；不需要为每个画框启动一个服务器。

### 添加纯 HTML 案例

在新目录放入 `index.html`、CSS 和 JS，再增加一个带上述 `dev/build` 脚本的私有 `package.json`。根目录已有 Vite，无需引入界面框架。多个 HTML 文件可分别作为画框路径。

纯 HTML 页面若要使用 Esc 桥，可以编写模块脚本：

```html
<script type="module">
  import { installPreviewBridge } from '@ui-atlas/preview-bridge'
  installPreviewBridge('http://127.0.0.1:4400')
</script>
```

并在该案例的 `dependencies` 中声明 `"@ui-atlas/preview-bridge": "workspace:*"`，再安装依赖。

### 接入现成源码

保留项目原有技术栈和路由，将源码放入本仓的案例目录，按实际启动命令登记 `preview`。纳入 workspace 的项目使用根 pnpm 安装依赖；已有锁文件、特殊目录结构或工具链可能需要少量适配。非 Vite 项目自行配置监听地址和固定端口，启动器不会向所有命令附加 Vite 参数。

画布直接访问案例端口，不把案例代理到统一子路径，从而保留静态资源路径、前端路由和热更新连接。依赖真实业务服务的源码应先改为本地 Mock 或准备其原有运行环境；本项目不创建业务后端。

任意网上链接可能被目标网站的嵌入策略阻止。这里用于展示已经在本地运行的页面，不提供绕过网站限制的功能。

### Esc 通信桥

不同端口的 iframe 属于跨源文档，画布无法直接监听内部键盘事件。案例可在入口处接入：

```ts
import { installPreviewBridge } from '@ui-atlas/preview-bridge'

const cleanup = installPreviewBridge('http://127.0.0.1:4400')
// 案例卸载时按需调用 cleanup()
```

桥只在 iframe 内生效，向指定的画布来源发送 `{ type: 'ui-atlas:exit-preview' }`。画布同时检查消息的来源与 iframe 窗口。内置案例从 `catalog.json` 读取画布地址；导入案例修改画布主机名或端口时，也要同步桥的参数。未接入桥仍可通过固定按钮退出交互。

## 数据保存

作品资料和默认布局始终来自 `catalog.json`。浏览器 localStorage 仅保存主题、最近作品，以及按作品 ID 区分的位置、缩放和视角。

清除浏览器数据或更换来源地址后会恢复默认值。浏览器禁止存储、保存数据损坏或布局版本不匹配时，画布仍可使用。调整既有作品的默认布局时递增其 `layoutVersion`，使旧布局失效；新增画框会使用配置中的默认位置。

这些偏好只保存在当前浏览器，不会写回源码，也不跨设备同步。

## 验证与排查

```bash
pnpm typecheck
pnpm test
pnpm build
# 或一次执行以上检查
pnpm check
```

测试覆盖画布几何、布局恢复，以及真实 HTTP/子进程 fixture 的就绪、超时、异常退出、端口占用和进程组清理。构建分别输出画布与各案例的 `dist/`；画布中的预览地址仍是本地服务地址，此项目没有整站静态发布打包流程。

- **端口已占用**：关闭你确认占用该端口的程序，或同时修改 catalog 和对应案例的启动端口。启动器不会结束其它项目的进程，也不会悄悄换端口。
- **启动超时**：查看终端里对应案例的输出，确认依赖、启动命令与本地 Mock 环境。默认在 30 秒内等待 HTTP 2xx；失败会停止本次启动的其它服务。
- **画框空白或加载失败**：直接打开画框的本地地址，核对路径和终端错误，再使用重新加载。iframe 的 `load` 事件不能证明页面内容已正确运行。
- **Esc 无效**：确认案例接入了桥，且画布地址一致；案例弹窗可能先消耗一次 Esc。随时可用画布的退出按钮。
- **位置与配置不一致**：使用恢复默认布局，或在修改默认布局后递增 `layoutVersion`。

本项目仅在本地交付和运行，不配置远程仓库、云同步或生产部署。

</details>
