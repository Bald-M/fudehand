import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import catalog from "../../catalog.json" with { type: "json" };

// catalog.json 是端口的唯一来源；启动器按同一地址等待就绪。
const { preview } = catalog.projects.find((project) => project.id === "still")!;

export default defineConfig({
  plugins: [vue()],
  server: {
    host: new URL(preview.baseUrl).hostname.replace(/^\[|\]$/g, ""),
    port: preview.port,
    strictPort: true,
  },
});
