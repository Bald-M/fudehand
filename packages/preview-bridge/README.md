# 预览通信桥

这个轻量工作区包让 Esc 键可以将焦点从可信的本地 iframe 返回界面图鉴画布。

```ts
import { installPreviewBridge } from "@ui-atlas/preview-bridge";
const cleanup = installPreviewBridge("http://127.0.0.1:4400");
```

更改外壳的主机名或端口时，需传入准确的外壳来源地址。两个内置案例都从 `catalog.json` 读取该地址。通信桥仅在 iframe 内生效，只向指定来源发送 `{ type: 'ui-atlas:exit-preview' }`；外壳还必须检查消息的来源与来源窗口。外壳中始终可见的退出按钮无需此通信桥即可使用。如果案例需要自行处理 Esc，可以在窗口监听器执行前调用 `event.preventDefault()`。

原生 `<dialog>` 打开时，Esc 留给弹窗处理，让浏览器先关闭弹窗。弹窗关闭后，再次按下 Esc 才会返回画布。
