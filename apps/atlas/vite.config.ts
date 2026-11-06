import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import catalog from '../../catalog.json' with { type: 'json' }

// catalog.json 是端口的唯一来源；启动器按同一地址等待就绪。
const shell = new URL(catalog.shell.url)

export default defineConfig({
  plugins: [vue()],
  server: { host: shell.hostname.replace(/^\[|\]$/g, ''), port: catalog.shell.port, strictPort: true },
})
