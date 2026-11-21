import { mkdir, readFile, rm, symlink } from 'node:fs/promises'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildNativeApp } from './native-build.mjs'
import { runCommand } from './native-swift.mjs'

// Builds the App for other Macs (no reference to this checkout; it carries its Node tools) and wraps it in a disk image with a link to
// /Applications: dist/Fudehand-<version>.dmg. Signing and notarization are not done here.
const root = fileURLToPath(new URL('../', import.meta.url))

try {
  const app = await buildNativeApp({ distribution: true })
  const { version } = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
  const staging = join(root, 'dist', 'dmg')
  const image = join(root, 'dist', `Fudehand-${version}.dmg`)
  await rm(staging, { recursive: true, force: true })
  await mkdir(staging, { recursive: true })
  await runCommand('ditto', [app, join(staging, 'Fudehand.app')])
  await symlink('/Applications', join(staging, 'Applications'))
  await rm(image, { force: true })
  await runCommand('hdiutil', ['create', '-volname', 'Fudehand', '-srcfolder', staging, '-fs', 'HFS+', '-format', 'UDZO', '-ov', image])
  await rm(staging, { recursive: true, force: true })
  console.log(`Disk image built: ${image}`)
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
