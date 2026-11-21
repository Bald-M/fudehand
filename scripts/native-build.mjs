import { randomUUID } from 'node:crypto'
import { chmod, copyFile, cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { runCommand, runSwift } from './native-swift.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))

// `distribution`: for an App given to other Macs (see scripts/native-package.mjs): it records nothing about this checkout and uses only
// the tools it carries.
export async function buildNativeApp({ configuration = 'release', distribution = false } = {}) {
  const scratch = await runSwift('build', { configuration })
  const app = join(root, 'dist', 'Fudehand.app')
  const contents = join(app, 'Contents')
  await mkdir(join(contents, 'MacOS'), { recursive: true })
  await mkdir(join(contents, 'Resources'), { recursive: true })
  await copyFile(join(scratch, configuration, 'FudehandApp'), join(contents, 'MacOS', 'FudehandApp'))
  await chmod(join(contents, 'MacOS', 'FudehandApp'), 0o755)
  await copyFile(join(root, 'native', 'Resources', 'Info.plist'), join(contents, 'Info.plist'))
  await copyFile(join(root, 'native', 'Resources', 'AppIcon.icns'), join(contents, 'Resources', 'AppIcon.icns'))
  await copyTemplates(join(contents, 'Resources', 'Templates'))
  await copyLocalizations(join(contents, 'Resources'))
  await copyIcons(join(contents, 'Resources', 'Icons'))
  await copyTools(join(contents, 'Resources', 'Tools'))
  // Local build metadata: the chat panel and the MCP connectors use the source workspace's scripts with this Node.
  const workspace = join(contents, 'Resources', 'workspace.json')
  if (distribution) await rm(workspace, { force: true })
  else await writeFile(workspace, JSON.stringify({ root, node: process.execPath, path: process.env.PATH || '' }, null, 2))
  await runCommand('codesign', ['--force', '--deep', '--sign', '-', app])
  console.log(`Native app built: ${app}`)
  return app
}

// The scripts the MCP server and the chat panel's Agent harness run, with their production dependencies, so an App without this checkout
// still works (it installs them to Application Support; see BundledTools). Node itself is not bundled.
const toolScripts = ['mcp-server.mjs', 'agent-chat.mjs', 'agent-providers.mjs', 'fudehand-tools.mjs', 'control-client.mjs', 'design-guidance.mjs', 'style-library.mjs']

async function copyTools(target) {
  await rm(target, { recursive: true, force: true })
  await mkdir(join(target, 'scripts'), { recursive: true })
  for (const name of ['package.json', 'pnpm-lock.yaml', '.npmrc']) await copyFile(join(root, name), join(target, name))
  for (const name of toolScripts) await copyFile(join(root, 'scripts', name), join(target, 'scripts', name))
  await cp(join(root, 'styles'), join(target, 'styles'), { recursive: true })
  // A flat node_modules of real files (pnpm's default layout is symbolic links into its store), from the lockfile and the local store.
  await runCommand('pnpm', ['install', '--prod', '--frozen-lockfile', '--prefer-offline', '--ignore-scripts', '--config.node-linker=hoisted', '--reporter=silent'], { cwd: target })
  for (const name of ['pnpm-lock.yaml', '.npmrc']) await rm(join(target, name))
  for (const name of ['.bin', '.pnpm', '.modules.yaml', '.pnpm-workspace-state-v1.json']) await rm(join(target, 'node_modules', name), { recursive: true, force: true })
  const { version } = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
  await writeFile(join(target, 'build-id'), `${version} ${randomUUID()}\n`)
}

// The launch window's templates: the .fudehand files under native/Resources/Templates/; clear first so deleted templates do not stay in the app bundle.
async function copyTemplates(target) {
  const source = join(root, 'native', 'Resources', 'Templates')
  await rm(target, { recursive: true, force: true })
  await mkdir(target, { recursive: true })
  for (const name of await readdir(source)) {
    if (name.toLowerCase().endsWith('.fudehand')) await copyFile(join(source, name), join(target, name))
  }
}

// The bundled icon libraries and their licenses (see scripts/build-icons.mjs); IconCatalog reads them from here.
async function copyIcons(target) {
  const source = join(root, 'native', 'Sources', 'FudehandCore', 'Resources', 'Icons')
  await rm(target, { recursive: true, force: true })
  await mkdir(target, { recursive: true })
  for (const name of await readdir(source)) await copyFile(join(source, name), join(target, name))
}

// UI string tables: the App reads them from its own bundle, and their presence tells AppKit which languages
// the system-provided menu items may use. Clear old ones first so a removed language does not linger.
async function copyLocalizations(resources) {
  const source = join(root, 'native', 'Sources', 'FudehandCore', 'Resources')
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
    const { values } = parseArgs({ options: { debug: { type: 'boolean', default: false }, distribution: { type: 'boolean', default: false } } })
    await buildNativeApp({ configuration: values.debug ? 'debug' : 'release', distribution: values.distribution })
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
