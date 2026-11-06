import { readFileSync } from 'node:fs'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// catalog.json 是端口的唯一来源；启动器按同一地址等待就绪。
// 读取文件而非 import，避免 Vite 把它当作配置依赖，在每次编辑目录时重启服务。
const catalog: { shell: { port: number; url: string } } = JSON.parse(readFileSync(new URL('../../catalog.json', import.meta.url), 'utf8'))

export default defineConfig({
  plugins: [vue()],
  server: { host: new URL(catalog.shell.url).hostname.replace(/^\[|\]$/g, ''), port: catalog.shell.port, strictPort: true },
})
