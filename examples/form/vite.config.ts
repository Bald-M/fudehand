import { readFileSync } from "node:fs";
import { defineConfig } from "vite";
import { previewGate } from "../../scripts/preview-gate.mjs";

// catalog.json 是端口的唯一来源；启动器按同一地址等待就绪。
// 读取文件而非 import，避免 Vite 把它当作配置依赖，在每次编辑目录时重启服务。
type Catalog = { projects: { id: string; preview: { port: number; baseUrl: string } }[] };
const catalog: Catalog = JSON.parse(readFileSync(new URL("../../catalog.json", import.meta.url), "utf8"));
const project = catalog.projects.find((item) => item.id === "form");
if (!project) throw new Error('catalog.json 中没有 id 为 "form" 的作品，无法确定预览端口。');

export default defineConfig({
  // 只允许 App 画框访问（带预览令牌 Cookie），浏览器直接打开端口会得到 403。
  plugins: [previewGate()],
  server: {
    host: new URL(project.preview.baseUrl).hostname.replace(/^\[|\]$/g, ""),
    port: project.preview.port,
    strictPort: true,
  },
});
