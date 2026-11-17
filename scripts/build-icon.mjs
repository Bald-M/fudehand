import { mkdir, mkdtemp, rename, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runCommand } from './native-swift.mjs'

const resources = fileURLToPath(new URL('../native/Resources/', import.meta.url))
const master = join(resources, 'AppIcon', 'AppIcon-1024.png')
const scratch = await mkdtemp(join(resources, '.app-icon-'))

try {
  const iconset = join(scratch, 'AppIcon.iconset')
  await mkdir(iconset)

  for (const points of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      const pixels = String(points * scale)
      const suffix = scale === 2 ? '@2x' : ''
      const output = join(iconset, `icon_${points}x${points}${suffix}.png`)
      await runCommand('/usr/bin/sips', ['-z', pixels, pixels, master, '--out', output])
    }
  }

  const icon = join(scratch, 'AppIcon.icns')
  await runCommand('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', icon])
  await rename(icon, join(resources, 'AppIcon.icns'))
} finally {
  await rm(scratch, { recursive: true, force: true })
}
