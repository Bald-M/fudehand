# 作品只在 App 画框中打开

> 已被 [ADR 0006](0006-native-design-document.md) 取代：网页作品链路已移除，本文只作历史记录。

2026-11-17。ui-atlas 的定位是作品只在 App 的画框里查看（#36）。此前画框标题栏有“在浏览器打开”按钮，跨域链接、`window.open` 与 `target=_blank` 会交给默认浏览器，且任何浏览器都能直接访问 `127.0.0.1` 上的预览端口。

现在画框不再调起浏览器：标题栏按钮删除，主框架离开作品本机服务的导航和新窗口请求一律忽略。预览端口用**预览令牌**把关：

- App（`PreviewSession`）每次启动启动器生成 32 字节随机令牌，经环境变量 `UI_ATLAS_PREVIEW_TOKEN` 交给 `native-preview.mjs`；启动器按需拉起的每个案例进程都继承它，就绪检查带上同一 Cookie。
- 启动启动器的同时，App 把令牌写入默认 `WKWebsiteDataStore` 的会话 Cookie `ui_atlas_preview`（`127.0.0.1`、`localhost`、`::1` 各一条；Cookie 不区分端口）。写入完成前，即使案例服务已就绪，作品也仍显示为启动中，所以画框创建时 Cookie 总已就位。
- 案例的 `vite.config.ts` 使用 `scripts/preview-gate.mjs` 的 `previewGate()` 插件，在 Vite 自身中间件之前拒绝没有该 Cookie 的 HTTP 请求（403）。页面、子资源和 HMR 客户端都由画框带 Cookie 请求，热更新不受影响。

## 否决的方案

- **自定义 URL scheme 或去掉 HTTP 开发服务**：要重写资源加载与热更新，超出范围（Issue 非目标）。
- **令牌放在画框 URL 的查询参数里，由服务端写 Cookie**：令牌会出现在页面地址与 Agent 返回的状态里，且同源导航需要额外处理；直接写 WKWebView 的 Cookie 更简单。
- **由启动器生成令牌再经 stdout 交给 App**：需要扩展启动器的 stdout 协议；App 本来就启动启动器，自己生成后经环境变量下传更直接。

## 影响

- 这是“浏览器无法顺手打开”，不是安全边界：本机其他程序仍可读取进程环境或抓取回环流量，不在防护范围内。
- 不经 App、单独运行案例的 `pnpm dev` 时没有令牌，插件不拦截，便于调试单个案例。
- 非 Vite 案例需自行实现同样的 Cookie 校验，否则仍可被浏览器直接访问。
- 内置案例都使用 `127.0.0.1`（已在真实 App 中验证）；`localhost` 与 `::1` 的 Cookie 一并写入，但 `::1` 尚未在 WebKit 中实测。
- MCP 的 `get_preview_urls` 只返回地址供参考；查看渲染结果用 `frame_snapshot`。
