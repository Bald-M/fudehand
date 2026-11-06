import { afterEach, describe, expect, it } from 'vitest'
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { assertPortsAvailable } from '../scripts/launcher.mjs'

const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

async function freePort() {
  const server = createServer()
  await new Promise<void>((done, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', done) })
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing fixture port')
  await new Promise<void>(done => server.close(() => done()))
  return { port: address.port, url: `http://127.0.0.1:${address.port}/` }
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'ui-atlas-native-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  await mkdir(join(root, 'examples/demo'), { recursive: true })
  const preview = await freePort()
  const script = join(root, 'examples/demo/dev.mjs')
  const marker = join(root, 'preview.pid')
  await writeFile(script, `import http from 'node:http'; import { writeFileSync } from 'node:fs';
    const server = http.createServer((request, response) => response.end('native-preview'));
    server.listen(${preview.port}, '127.0.0.1', () => writeFileSync(${JSON.stringify(marker)}, String(process.pid)));
    process.on('SIGTERM', () => server.close(() => process.exit(0)));
  `)
  const catalog = {
    version: 1,
    projects: [{ id: 'demo', title: '演示', subtitle: '', description: '', author: '', sourceUrl: null,
      framework: 'HTML', tags: [], enabled: true, layoutVersion: 1,
      preview: { cwd: 'examples/demo', command: [process.execPath, script], port: preview.port, baseUrl: preview.url },
      frames: [{ id: 'home', title: '首页', platform: 'web', path: '/', width: 640, height: 480, x: 0, y: 0 }],
    }],
  }
  await writeFile(join(root, 'catalog.json'), JSON.stringify(catalog))
  return { root, marker, preview, catalog }
}

function launch(root: string) {
  const child = spawn(process.execPath, [resolve('scripts/native-preview.mjs'), '--root', root], { stdio: 'pipe' })
  let output = ''
  let errors = ''
  child.stdout.on('data', chunk => { output += chunk })
  child.stderr.on('data', chunk => { errors += chunk })
  const exited = new Promise<number | null>(done => child.once('exit', code => done(code)))
  cleanup.push(async () => {
    child.stdin.end()
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM')
    await exited
  })
  async function ready() {
    for (let count = 0; count < 100; count++) {
      if (output.split('\n').includes('UI_ATLAS_READY')) return
      if (child.exitCode !== null) throw new Error(`Preview exited: ${errors}`)
      await delay(30)
    }
    throw new Error(`Preview did not become ready: ${errors}`)
  }
  return { child, exited, ready, output: () => output, errors: () => errors }
}

describe('原生案例服务入口', () => {
  it('启动案例，并在 App 管道关闭后释放案例端口', async () => {
    const sample = await fixture()
    const running = launch(sample.root)
    await running.ready()
    expect(running.output()).toBe('UI_ATLAS_READY\n')
    expect(await (await fetch(sample.preview.url)).text()).toBe('native-preview')
    const pid = Number(await readFile(sample.marker, 'utf8'))
    running.child.stdin.end()
    expect(await running.exited).toBe(0)
    await expect(assertPortsAvailable([{ ...sample.preview, title: '案例' }])).resolves.toBeUndefined()
    expect(() => process.kill(pid, 0)).toThrow()
  })

  it('收到终止信号时清理本次案例进程', async () => {
    const sample = await fixture()
    const running = launch(sample.root)
    await running.ready()
    running.child.kill('SIGTERM')
    expect(await running.exited).toBe(0)
    await expect(assertPortsAvailable([{ ...sample.preview, title: '案例' }])).resolves.toBeUndefined()
  })

  it('案例端口被占用时报告失败，保留占用该端口的服务', async () => {
    const sample = await fixture()
    const occupied = createServer((_request, response) => response.end('keep-running'))
    await new Promise<void>((done, reject) => {
      occupied.once('error', reject)
      occupied.listen(sample.preview.port, '127.0.0.1', done)
    })
    cleanup.push(() => new Promise<void>(done => occupied.close(() => done())))
    const running = launch(sample.root)
    expect(await running.exited).toBe(1)
    expect(running.output()).toBe('')
    expect(running.errors()).toContain(String(sample.preview.port))
    expect(await (await fetch(sample.preview.url)).text()).toBe('keep-running')
  })

  it('已就绪的案例异常退出时报告失败并释放端口', async () => {
    const sample = await fixture()
    const running = launch(sample.root)
    await running.ready()
    const pid = Number(await readFile(sample.marker, 'utf8'))
    process.kill(pid, 'SIGKILL')
    expect(await running.exited).toBe(1)
    expect(running.errors()).toContain('意外退出')
    await expect(assertPortsAvailable([{ ...sample.preview, title: '案例' }])).resolves.toBeUndefined()
  })
})
