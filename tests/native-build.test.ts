import { execFileSync } from 'node:child_process'
import { closeSync, cpSync, fchmodSync, mkdirSync, mkdtempSync, openSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

const root = join(import.meta.dirname, '..')

describe.skipIf(process.platform !== 'darwin')('native App build', () => {
  let fixture: string
  let dist: string
  let app: string
  let executable: string
  let scratch: string
  let bin: string

  beforeEach(() => {
    fixture = mkdtempSync(join(realpathSync(tmpdir()), 'fudehand-build-test-'))
    dist = join(fixture, 'dist')
    app = join(dist, 'Fudehand.app')
    executable = join(app, 'Contents/MacOS/FudehandApp')
    scratch = join(fixture, 'scratch')
    bin = join(fixture, 'bin')
    for (const path of ['native/Resources/Templates', 'native/Sources/FudehandCore/Resources/Icons', 'styles', 'scratch/release', 'bin']) {
      mkdirSync(join(fixture, path), { recursive: true })
    }
    cpSync(join(root, 'scripts'), join(fixture, 'scripts'), { recursive: true })
    for (const file of ['package.json', 'pnpm-lock.yaml', '.npmrc', 'native/Resources/Info.plist', 'native/Resources/AppIcon.icns']) {
      cpSync(join(root, file), join(fixture, file))
    }
    // Keep the real assembly, signing and publish steps, with a small prebuilt Mach-O and no dependency install.
    for (const command of ['swift', 'pnpm']) {
      writeFileSync(join(bin, command), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    }
  })

  afterEach(() => rmSync(fixture, { recursive: true, force: true }))

  function build(version: string, signingFails = false) {
    const source = join(fixture, 'probe.c')
    writeFileSync(source, `#include <stdio.h>\nint main(void) { puts("${version}"); }\n`)
    execFileSync('/usr/bin/clang', [source, '-o', join(scratch, 'release/FudehandApp')])
    writeFileSync(join(bin, 'codesign'), signingFails ? '#!/bin/sh\nexit 1\n' : '#!/bin/sh\nexec /usr/bin/codesign "$@"\n', { mode: 0o755 })
    execFileSync(process.execPath, [join(fixture, 'scripts/native-build.mjs')], {
      cwd: fixture,
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        FUDEHAND_SWIFT_SCRATCH: scratch,
        FUDEHAND_SWIFT_MODULE_CACHE: join(scratch, 'modules'),
      },
    })
  }

  function expectPublishedVersion(version: string) {
    execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app])
    expect(execFileSync(executable, { encoding: 'utf8' }).trim()).toBe(version)
  }

  it('publishes a new signed App without rewriting the old bundle or executable inode', () => {
    build('before')
    expectPublishedVersion('before')
    const original = [app, executable].map(path => statSync(path).ino)

    build('after')

    expectPublishedVersion('after')
    expect(readdirSync(dist)).toEqual(['Fudehand.app'])
    for (const [index, path] of [app, executable].entries()) {
      expect(statSync(path).ino).not.toBe(original[index])
    }
  })

  it('keeps the previous App signed and runnable after a signing failure', () => {
    build('before')
    const original = [app, executable].map(path => statSync(path).ino)

    expect(() => build('after', true)).toThrow('codesign --force failed')

    expectPublishedVersion('before')
    expect(readdirSync(dist)).toEqual(['Fudehand.app'])
    expect([app, executable].map(path => statSync(path).ino)).toEqual(original)
  })

  it('keeps a successful publish usable when cleanup of the old App fails', () => {
    build('before')
    const oldMacOS = openSync(join(app, 'Contents/MacOS'), 'r')
    try {
      fchmodSync(oldMacOS, 0o555)
      expectPublishedVersion('before')

      build('after')

      expectPublishedVersion('after')
    } finally {
      // The descriptor still identifies the old directory after the bundle moves.
      fchmodSync(oldMacOS, 0o755)
      closeSync(oldMacOS)
    }
  })
})
