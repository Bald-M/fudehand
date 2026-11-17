import { chmod, copyFile, mkdir, readdir, rm, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { runCommand, runSwift } from './native-swift.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))

export async function buildNativeApp({ configuration = 'release' } = {}) {
  const scratch = await runSwift('build', { configuration })
  const app = join(root, 'dist', 'ui-atlas.app')
  const contents = join(app, 'Contents')
  await mkdir(join(contents, 'MacOS'), { recursive: true })
  await mkdir(join(contents, 'Resources'), { recursive: true })
  await copyFile(join(scratch, configuration, 'AtlasApp'), join(contents, 'MacOS', 'AtlasApp'))
  await chmod(join(contents, 'MacOS', 'AtlasApp'), 0o755)
  await copyFile(join(root, 'native', 'Resources', 'Info.plist'), join(contents, 'Info.plist'))
  await copyFile(join(root, 'native', 'Resources', 'AppIcon.icns'), join(contents, 'Resources', 'AppIcon.icns'))
  await copyTemplates(join(contents, 'Resources', 'Templates'))
  await copyLocalizations(join(contents, 'Resources'))
  // Local build metadata: the chat panel starts the source workspace's Agent harness with this Node.
  await writeFile(join(contents, 'Resources', 'workspace.json'), JSON.stringify({ root, node: process.execPath, path: process.env.PATH || '' }, null, 2))
  await runCommand('codesign', ['--force', '--deep', '--sign', '-', app])
  console.log(`Native app built: ${app}`)
  return app
}

// The launch window's templates: the .uiatlas files under native/Resources/Templates/; clear first so deleted templates do not stay in the app bundle.
async function copyTemplates(target) {
  const source = join(root, 'native', 'Resources', 'Templates')
  await rm(target, { recursive: true, force: true })
  await mkdir(target, { recursive: true })
  for (const name of await readdir(source)) {
    if (name.toLowerCase().endsWith('.uiatlas')) await copyFile(join(source, name), join(target, name))
  }
}

// UI string tables: the App reads them from its own bundle, and their presence tells AppKit which languages
// the system-provided menu items may use. Clear old ones first so a removed language does not linger.
async function copyLocalizations(resources) {
  const source = join(root, 'native', 'Sources', 'AtlasCore', 'Resources')
  for (const name of await readdir(resources)) {
    if (name.endsWith('.lproj')) await rm(join(resources, name), { recursive: true, force: true })
  }
  for (const name of await readdir(source)) {
    if (!name.endsWith('.lproj')) continue
    await mkdir(join(resources, name), { recursive: true })
    await copyFile(join(source, name, 'Localizable.strings'), join(resources, name, 'Localizable.strings'))
  }
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
