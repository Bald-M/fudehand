import { afterEach, describe, expect, it } from 'vitest'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const repo = fileURLToPath(new URL('../', import.meta.url))
const script = join(repo, 'scripts', 'version.mjs')
const plistPath = join('native', 'Resources', 'Info.plist')
const roots: string[] = []
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }) })

async function copyOfRepo() {
  const root = await mkdtemp(join(tmpdir(), 'fudehand-version-'))
  roots.push(root)
  await mkdir(join(root, 'native', 'Resources'), { recursive: true })
  await copyFile(join(repo, 'package.json'), join(root, 'package.json'))
  await copyFile(join(repo, plistPath), join(root, plistPath))
  return root
}

function run(root: string, ...args: string[]) {
  const result = spawnSync(process.execPath, [script, ...args, '--root', root], { encoding: 'utf8' })
  return { status: result.status, output: result.stdout + result.stderr }
}

const read = (root: string, path: string) => readFile(join(root, path), 'utf8')
const shortVersion = (plist: string) => plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]*)<\/string>/)?.[1]
const buildNumber = (plist: string) => Number(plist.match(/<key>CFBundleVersion<\/key>\s*<string>([^<]*)<\/string>/)?.[1])

describe('version:set', () => {
  it('sets every location to one version, bumps the build number, and leaves the rest untouched', async () => {
    const root = await copyOfRepo()
    const pkgBefore = await read(root, 'package.json')
    const plistBefore = await read(root, plistPath)

    const result = run(root, 'set', '1.2.3-beta.1')
    expect(result.status).toBe(0)

    const pkgAfter = await read(root, 'package.json')
    const plistAfter = await read(root, plistPath)
    expect(JSON.parse(pkgAfter).version).toBe('1.2.3-beta.1')
    expect(shortVersion(plistAfter)).toBe('1.2.3-beta.1')
    expect(buildNumber(plistAfter)).toBe(buildNumber(plistBefore) + 1)
    expect(pkgAfter).toBe(pkgBefore.replace(`"version": "${JSON.parse(pkgBefore).version}"`, '"version": "1.2.3-beta.1"'))
    expect(plistAfter).toBe(plistBefore
      .replace(`<string>${shortVersion(plistBefore)}</string>`, '<string>1.2.3-beta.1</string>')
      .replace(`<key>CFBundleVersion</key>\n\t<string>${buildNumber(plistBefore)}</string>`, `<key>CFBundleVersion</key>\n\t<string>${buildNumber(plistBefore) + 1}</string>`))
    expect(result.output).toContain(`${JSON.parse(pkgBefore).version} → 1.2.3-beta.1`)
    expect(result.output).toContain(`${buildNumber(plistBefore)} → ${buildNumber(plistBefore) + 1}`)
  })

  it.each([['1.0'], ['v1.0.0'], ['01.0.0'], ['1.0.0-'], ['']])('rejects invalid version %j without changing any file', async (version) => {
    const root = await copyOfRepo()
    const pkgBefore = await read(root, 'package.json')
    const plistBefore = await read(root, plistPath)

    const result = run(root, 'set', ...(version ? [version] : []))
    expect(result.status).not.toBe(0)
    expect(result.output).toContain('x.y.z')
    expect(await read(root, 'package.json')).toBe(pkgBefore)
    expect(await read(root, plistPath)).toBe(plistBefore)
  })
})

describe('version:check', () => {
  it('exits 0 when every location agrees', async () => {
    const root = await copyOfRepo()
    expect(run(root, 'check').status).toBe(0)
  })

  it('exits non-zero and names the file when versions differ', async () => {
    const root = await copyOfRepo()
    const plist = await read(root, plistPath)
    await writeFile(join(root, plistPath), plist.replace(`<string>${shortVersion(plist)}</string>`, '<string>9.9.9</string>'))

    const result = run(root, 'check')
    expect(result.status).not.toBe(0)
    expect(result.output).toContain('native/Resources/Info.plist')
    expect(result.output).toContain('9.9.9')
  })
})
