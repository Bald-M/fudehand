import { buildNativeApp } from './native-build.mjs'
import { runCommand } from './native-swift.mjs'

try {
  const app = await buildNativeApp({ configuration: 'debug' })
  await runCommand('open', [app])
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
