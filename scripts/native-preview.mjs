import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { readServices, runServices } from './launcher.mjs'

const controller = new AbortController()
const stop = () => controller.abort()
process.once('SIGINT', stop)
process.once('SIGTERM', stop)
// The App owns this pipe. EOF also handles an App crash without orphaning previews.
process.stdin.once('end', stop)
process.stdin.resume()
process.stdout.once('error', stop)

try {
  const { values } = parseArgs({ options: { root: { type: 'string' } } })
  const root = values.root ? resolve(values.root) : fileURLToPath(new URL('../', import.meta.url))
  const services = await readServices(root)
  await runServices(services, {
    signal: controller.signal,
    stdio: ['ignore', process.stderr, process.stderr],
    log: message => console.error(message),
    onReady: () => process.stdout.write('UI_ATLAS_READY\n'),
  })
} catch (error) {
  console.error(`[界面图鉴] ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
} finally {
  process.removeListener('SIGINT', stop)
  process.removeListener('SIGTERM', stop)
  process.stdin.removeListener('end', stop)
  process.stdin.pause()
  process.stdout.removeListener('error', stop)
}
