# 界面图鉴

一个放在本机的界面学习画布。把喜欢的设计复刻为可交互的页面，或接入现成前端源码，在同一张画布里比较移动、网页和桌面界面。

外壳是 **SwiftUI + AppKit 原生 macOS App**：作品侧栏、工具栏、画布和偏好由 Swift 实现，Vue/React/HTML 案例保留各自的工具链，通过系统 WebKit 展示。Node 脚本只负责启动和清理案例开发服务。

## 开始使用

需要 macOS 14+、Swift 6+（Xcode Command Line Tools 即可）、Node.js **22.12+** 和 pnpm **11.7.0**。

```bash
pnpm install
pnpm dev
```

`pnpm dev` 构建并打开 App，App 自动启动 `enabled: true` 的案例服务，退出时清理服务。

| 案例 | 地址 | 内容 |
| --- | --- | --- |
| 留白 | `http://127.0.0.1:4401/` | Vue 原创三端日常计划工具 |
| 灵感原野 | `http://127.0.0.1:4402/` | React 原创灵感收集器 |

- 发布优化构建：`pnpm build:native`，然后双击 `dist/界面图鉴.app`。
- 原生测试：`pnpm test:native`；案例与启动器检查：`pnpm check`。

画布操作、构建、保存和边界说明见 [macOS 使用说明](docs/macos.md)。App 使用本地源码目录和 Node/pnpm，当前是本机构建，不是脱离源码的独立分发包。网页案例仍有 WebKit 渲染开销。

手机、网页、桌面是不同尺寸的 **CSS 视口**，不模拟设备系统、像素密度或原生能力。

## 目录与配置

```text
native/                    SwiftUI + AppKit 原生 App 与 Swift 测试
examples/still/            Vue 三端案例
examples/form/             React 案例
catalog.json               作品资料、画框与启动配置的权威来源
scripts/                   原生构建、测试，以及案例服务的启动与清理
```

新增案例时，把源码放到 `examples/<作品名>/`，在 `catalog.json` 的 `projects` 中加入一项：

```json
{
  "id": "my-study",
  "title": "我的设计习作",
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
- `enabled` 控制 App 是否启动该案例。所有作品的端口仍须独立，包括暂时停用的作品。
- `preview.cwd` 是相对仓库根目录的现存目录；`command` 是直接执行的参数数组，不支持 shell 管道、`&&` 或环境变量展开。
- `port` 是端口的唯一来源。内置案例的 `vite.config.ts` 直接读取 `catalog.json` 中对应的 `preview.port` 和 `preview.baseUrl` 主机名，并开启严格端口检查，修改配置即可。非 Vite 案例的命令需自行监听同一端口。
- `baseUrl` 使用与端口一致的本机 HTTP 地址。可使用 `127.0.0.1`、`localhost` 或 `::1`，但日常固定使用 `127.0.0.1`。
- 画框 `width/height` 是正数，`x/y` 是画布中的有限坐标。`platform` 使用 `mobile`、`web` 或 `desktop`。
- 修改案例目录、命令、端口、启用状态或画框配置后，在 App 中使用“重新读取目录并启动服务”。

画框路径使用 `new URL(path, baseUrl)` 解析：当基础地址是 `http://127.0.0.1:4403/demo/` 时，`login` 指向 `/demo/login`，`/login` 指向站点根目录的 `/login`。支持查询参数与哈希路由；画框应指向该作品自己的本地服务。多个画框共享一个案例进程。

### 添加 Vue 或 React 案例

复制对应的内置案例到新目录，修改包名、页面内容，以及 `vite.config.ts` 里查找的作品 `id`，再增加配置项。`vite.config.ts` 从 `catalog.json` 读取端口和主机名：

```ts
import { readFileSync } from "node:fs";
import { defineConfig } from "vite";

type Catalog = { projects: { id: string; preview: { port: number; baseUrl: string } }[] };
const catalog: Catalog = JSON.parse(readFileSync(new URL("../../catalog.json", import.meta.url), "utf8"));
const project = catalog.projects.find((item) => item.id === "demo");
if (!project) throw new Error('catalog.json 中没有 id 为 "demo" 的作品，无法确定预览端口。');

export default defineConfig({
  server: { host: new URL(project.preview.baseUrl).hostname.replace(/^\[|\]$/g, ""), port: project.preview.port, strictPort: true },
});
```

配置用 `readFileSync` 而不是 `import` 读取 `catalog.json`，这样编辑目录不会让 Vite 重启所有案例服务；修改端口后需在 App 中重新读取目录并启动服务。Vue 案例另加 `plugins: [vue()]`。

`package.json` 中使用 `"dev": "vite"` 和 `"build": "vite build"`。

新目录由 pnpm 工作区管理。改完依赖后在根目录执行 `pnpm install`。同一作品可用不同路径或查询参数实现多个页面；不需要为每个画框启动一个服务器。

### 添加纯 HTML 案例

在新目录放入 `index.html`、CSS 和 JS，再增加一个带上述 `dev/build` 脚本的私有 `package.json` 和上面的 `vite.config.ts`。根目录已有 Vite，无需引入界面框架。多个 HTML 文件可分别作为画框路径。

### 接入现成源码

保留项目原有技术栈和路由，将源码放入本仓的案例目录，按实际启动命令登记 `preview`。纳入工作区的项目使用根 pnpm 安装依赖；已有锁文件、特殊目录结构或工具链可能需要少量适配。非 Vite 项目自行配置监听地址和固定端口，启动器不会向所有命令附加 Vite 参数。

App 直接访问案例端口，不把案例代理到统一子路径，从而保留静态资源路径、前端路由和热更新连接。依赖真实业务服务的源码应先改为本地模拟或准备其原有运行环境；本项目不创建业务后端。

任意网上链接可能被目标网站的嵌入策略阻止。这里用于展示已经在本地运行的页面，不提供绕过网站限制的功能。

## 验证与排查

```bash
pnpm test:native
pnpm check   # 类型检查、Vitest 与案例构建
```

Node 测试使用真实 HTTP/子进程测试样例，覆盖就绪、超时、异常退出、端口占用和进程组清理。目录校验规则写在 `tests/fixtures/catalog-conformance.json`，Node 启动器与原生 App 的测试都执行这份用例，修改规则时两端需同时通过。构建输出各案例的 `dist/`；画框中的预览地址仍是本地服务地址，此项目没有整站静态发布打包流程。

- **端口已占用**：关闭你确认占用该端口的程序，或修改 `catalog.json` 中的端口（非 Vite 案例还需同步其启动命令）。App 显示具体错误并提供重试，不会结束其它项目的进程，也不会悄悄换端口。
- **启动超时**：确认依赖、启动命令与本地模拟环境。默认在 30 秒内等待 HTTP 2xx；失败会停止本次启动的其它服务。
- **画框空白或加载失败**：使用标题栏按钮在浏览器打开画框的本地地址，核对路径，再重载当前作品。
- **位置与配置不一致**：使用恢复默认布局，或在修改默认布局后递增 `layoutVersion`。

本项目仅在本地交付和运行，不配置远程仓库、云同步或生产部署。
