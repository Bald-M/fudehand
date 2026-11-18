import { spawn } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url))

export function runCommand(executable, args, options = {}) {
  return new Promise((done, reject) => {
    const child = spawn(executable, args, { stdio: 'inherit', shell: false, ...options })
    child.once('error', reject)
    child.once('exit', (code, signal) => code === 0 ? done() : reject(new Error(`${executable} ${args[0]} failed (${signal || code})`)))
  })
}

export async function runSwift(operation, { configuration = 'debug', args = [], env = {} } = {}) {
  if (process.platform !== 'darwin') throw new Error('The native app must be built and tested on macOS.')
  const configured = process.env.UI_ATLAS_SWIFT_SCRATCH
  const scratch = configured
    ? resolve(configured, operation === 'test' ? 'tests' : '.')
    : `/private/tmp/ui-atlas-native-${operation === 'test' ? 'tests' : 'release'}`
  const cache = join(scratch, 'cache')
  const modules = resolve(process.env.UI_ATLAS_SWIFT_MODULE_CACHE || '/private/tmp/ui-atlas-core-module-cache')
  await Promise.all([mkdir(cache, { recursive: true }), mkdir(modules, { recursive: true })])
  await runCommand('swift', [
    operation, '--package-path', join(root, 'native'), '--configuration', configuration,
    '--scratch-path', scratch, '--cache-path', cache, '--config-path', join(scratch, 'configuration'),
    '--security-path', join(scratch, 'security'), '--disable-sandbox', ...args,
  ], {
    cwd: root,
    env: { ...process.env, ...env, CLANG_MODULE_CACHE_PATH: modules, SWIFTPM_MODULECACHE_OVERRIDE: modules },
  })
  return scratch
}
