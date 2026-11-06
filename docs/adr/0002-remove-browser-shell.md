# 移除浏览器兼容版

2026-11-06，用户要求完整移除浏览器兼容版。原生 macOS App（见 [0001](0001-native-macos-shell.md)）是唯一外壳：删除 `apps/atlas` Vue 画布、`pnpm dev:web` 入口与 `scripts/dev.mjs`，以及只服务于 iframe 画布的 `packages/preview-bridge` Esc 通信桥。原生 App 自行向 WKWebView 注入 Esc 退出脚本，案例无需接入任何桥。

`catalog.json` 不再包含 `shell`（4400 画布端口）字段，版本号仍为 1；旧配置里残留的 `shell` 会被两端校验忽略。浏览器 localStorage 中的偏好不迁移。原浏览器版的需求基线与验收记录（`docs/implementation-plan.md`、`docs/verification.md`）随之删除，可在 Git 历史中查阅。
