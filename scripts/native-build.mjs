import { chmod, copyFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { runCommand, runSwift } from './native-swift.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))

export async function buildNativeApp({ configuration = 'release' } = {}) {
  const scratch = await runSwift('build', { configuration })
  const app = join(root, 'dist', '界面图鉴.app')
  const contents = join(app, 'Contents')
  await mkdir(join(contents, 'MacOS'), { recursive: true })
  await mkdir(join(contents, 'Resources'), { recursive: true })
  await copyFile(join(scratch, configuration, 'AtlasApp'), join(contents, 'MacOS', 'AtlasApp'))
  await chmod(join(contents, 'MacOS', 'AtlasApp'), 0o755)
  await copyFile(join(root, 'native', 'Resources', 'Info.plist'), join(contents, 'Info.plist'))
  // Local build metadata: the App still runs the source workspace's Node previews.
  await writeFile(join(contents, 'Resources', 'workspace.json'), JSON.stringify({ root, node: process.execPath, path: process.env.PATH || '' }, null, 2))
  await runCommand('codesign', ['--force', '--deep', '--sign', '-', app])
  console.log(`原生 App 已构建：${app}`)
  return app
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const { values } = parseArgs({ options: { debug: { type: 'boolean', default: false } } })
    await buildNativeApp({ configuration: values.debug ? 'debug' : 'release' })
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
