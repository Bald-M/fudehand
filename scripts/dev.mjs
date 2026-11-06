import { fileURLToPath } from 'node:url'
import { readServices, runServices } from './launcher.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const controller = new AbortController()
const stop = () => controller.abort()
process.once('SIGINT', stop)
process.once('SIGTERM', stop)
try {
  const services = await readServices(root)
  await runServices(services, {
    signal: controller.signal,
    onReady: () => console.log(`\nUI Atlas 已就绪 → ${services[0].url}\n已启动 ${services.length - 1} 个案例。按 Ctrl+C 统一停止。\n`),
  })
} catch (error) {
  console.error(`\n[UI Atlas] ${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
} finally {
  process.removeListener('SIGINT', stop)
  process.removeListener('SIGTERM', stop)
}
