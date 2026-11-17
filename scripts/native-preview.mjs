import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { parseArgs } from 'node:util'
import { createServicePool, readServices } from './launcher.mjs'

// 协议（每行一条）：App → stdin `start <id>`；stdout → App `UI_ATLAS_LISTENING`、
// `UI_ATLAS_READY <id>`、`UI_ATLAS_FAILED <id> <JSON 字符串>`。日志只写 stderr。
let finish
const finished = new Promise(resolveFinish => { finish = resolveFinish })
const stop = () => finish()
process.once('SIGINT', stop)
process.once('SIGTERM', stop)
process.stdout.once('error', stop)

let pool
try {
  const { values } = parseArgs({ options: { root: { type: 'string' } } })
  const root = values.root ? resolve(values.root) : fileURLToPath(new URL('../', import.meta.url))
  const services = await readServices(root)
  pool = createServicePool(services, {
    stdio: ['ignore', process.stderr, process.stderr],
    log: message => console.error(message),
    onReady: id => process.stdout.write(`UI_ATLAS_READY ${id}\n`),
    onFailed: (id, error) => process.stdout.write(`UI_ATLAS_FAILED ${id} ${JSON.stringify(error.message)}\n`),
  })
  // The App owns this pipe. EOF also handles an App crash without orphaning previews.
  const commands = createInterface({ input: process.stdin })
  commands.on('line', line => {
    const [command, id] = line.trim().split(/\s+/)
    if (command === 'start' && id) pool.start(id).catch(() => {})
  })
  commands.once('close', stop)
  process.stdout.write('UI_ATLAS_LISTENING\n')
  await finished
  commands.close()
} catch (error) {
  console.error(`[界面图鉴] ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
} finally {
  await pool?.close()
  process.removeListener('SIGINT', stop)
  process.removeListener('SIGTERM', stop)
  process.stdout.removeListener('error', stop)
  process.stdin.pause()
}
