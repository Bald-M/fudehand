import { afterEach, describe, expect, it } from 'vitest'
import { createServer, type RequestListener } from 'node:http'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { assertPortsAvailable, createServicePool, servicesFromCatalog, waitForHttp } from '../scripts/launcher.mjs'

const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

async function tempDirectory() {
  const path = await mkdtemp(join(tmpdir(), 'ui-atlas-launcher-'))
  cleanup.push(() => rm(path, { recursive: true, force: true }))
  return path
}

async function httpServer(handler: RequestListener) {
  const server = createServer(handler)
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('未获得测试端口')
  cleanup.push(async () => {
    server.closeAllConnections()
    await new Promise<void>(resolve => server.close(() => resolve()))
  })
  return { server, port: address.port, url: `http://127.0.0.1:${address.port}/` }
}

async function unusedPort() {
  const server = createServer()
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('未获得测试端口')
  await new Promise<void>(resolve => server.close(() => resolve()))
  return address.port
}

const fixtureCode = `
import http from 'node:http'
import { writeFileSync } from 'node:fs'
const [port, marker, wait = '0', mode = 'normal'] = process.argv.slice(2)
const readyAt = Date.now() + Number(wait)
const server = http.createServer((request, response) => {
  response.writeHead(Date.now() < readyAt ? 503 : 200)
  response.end('fixture')
})
server.listen(Number(port), '127.0.0.1', () => writeFileSync(marker, String(process.pid)))
process.on('SIGTERM', () => {
  if (mode !== 'ignore') server.close(() => process.exit(0))
})
`

async function fixture(wait = 0, mode = 'normal') {
  const cwd = await tempDirectory()
  const script = join(cwd, 'server.mjs')
  const marker = join(cwd, 'pid')
  await writeFile(script, fixtureCode)
  const port = await unusedPort()
  return {
    marker, script,
    service: { id: 'fixture', title: '测试样例', cwd, command: [process.execPath, script, String(port), marker, String(wait), mode], port, url: `http://127.0.0.1:${port}/` },
  }
}

function supervised(services: object[], options: Record<string, unknown> = {}) {
  const events: string[] = []
  const pool = createServicePool(services, {
    stdio: 'ignore', log: () => {}, shutdownGraceMs: 100,
    onReady: (id: string) => events.push(`ready ${id}`),
    onFailed: (id: string, error: Error) => events.push(`failed ${id} ${error.message}`),
    ...options,
  })
  cleanup.push(() => pool.close())
  return { pool, events }
}

async function fixtureCatalog() {
  const cwd = await tempDirectory()
  await mkdir(join(cwd, 'examples/demo'), { recursive: true })
  return { cwd, catalog: {
    version: 1,
    projects: [{ id: 'demo', title: '演示作品', subtitle: '', description: '', author: '原创作者', sourceUrl: null as string | null, framework: 'HTML', tags: ['演示'], enabled: true, layoutVersion: 1,
      preview: { cwd: 'examples/demo', command: [process.execPath, 'dev.mjs'], port: 31002, baseUrl: 'http://127.0.0.1:31002/demo/' },
      frames: [{ id: 'home', title: '首页', platform: 'web', path: 'home', width: 1440, height: 900, x: 0, y: 0 }],
    }],
  } }
}

describe('作品目录与本地服务', () => {
  it('保持已启用作品相互独立，并支持空作品集', async () => {
    const { cwd, catalog } = await fixtureCatalog()
    const services = await servicesFromCatalog(catalog, cwd)
    expect(services.map((service: { id: string }) => service.id)).toEqual(['demo'])
    expect(services[0].cwd).toBe(join(cwd, 'examples/demo'))
    catalog.projects[0].enabled = false
    expect(await servicesFromCatalog(catalog, cwd)).toHaveLength(0)
    catalog.projects = []
    expect(await servicesFromCatalog(catalog, cwd)).toHaveLength(0)
  })

  it('拒绝重复端口、非本机地址、无效几何数据和越界目录', async () => {
    const { cwd, catalog } = await fixtureCatalog()
    const duplicate = structuredClone(catalog)
    duplicate.projects.push({ ...structuredClone(duplicate.projects[0]), id: 'demo-two' })
    await expect(servicesFromCatalog(duplicate, cwd)).rejects.toThrow('重复')
    const remote = structuredClone(catalog)
    remote.projects[0].preview.baseUrl = 'http://example.com:31002/'
    await expect(servicesFromCatalog(remote, cwd)).rejects.toThrow('本机 HTTP')
    const geometry = structuredClone(catalog)
    geometry.projects[0].frames[0].width = 0
    await expect(servicesFromCatalog(geometry, cwd)).rejects.toThrow('宽高')
    const escaping = structuredClone(catalog)
    escaping.projects[0].preview.cwd = '../other'
    await expect(servicesFromCatalog(escaping, cwd)).rejects.toThrow('不能离开')
    const invalidTags = structuredClone(catalog)
    Reflect.deleteProperty(invalidTags.projects[0], 'tags')
    await expect(servicesFromCatalog(invalidTags, cwd)).rejects.toThrow('tags')
    Reflect.set(invalidTags.projects[0], 'tags', [123])
    await expect(servicesFromCatalog(invalidTags, cwd)).rejects.toThrow('tags')
    const invalidSource = structuredClone(catalog)
    invalidSource.projects[0].sourceUrl = 'javascript:alert(1)'
    await expect(servicesFromCatalog(invalidSource, cwd)).rejects.toThrow('sourceUrl')
    const frame = structuredClone(catalog)
    frame.projects[0].frames[0].path = 'https://example.com/'
    await expect(servicesFromCatalog(frame, cwd)).rejects.toThrow('本地预览服务')
  })

  it('报告端口占用，并保持既有服务正常运行', async () => {
    const occupied = await httpServer((_request, response) => response.end('existing'))
    const service = { title: '已在运行的服务', port: occupied.port, url: occupied.url }
    await expect(assertPortsAvailable([service])).rejects.toThrow(`端口 ${occupied.port}`)
    expect(await (await fetch(occupied.url)).text()).toBe('existing')
  })

  it('等待 HTTP 成功响应，开放套接字不足以判定就绪', async () => {
    const readyAt = Date.now() + 120
    const endpoint = await httpServer((_request, response) => { response.writeHead(Date.now() < readyAt ? 503 : 200); response.end() })
    await waitForHttp(endpoint.url, { timeoutMs: 1000, intervalMs: 15 })
    expect(Date.now()).toBeGreaterThanOrEqual(readyAt)
  })

  it('对异常 HTTP 响应超时退出，并及时取消挂起的请求', async () => {
    const unhealthy = await httpServer((_request, response) => { response.writeHead(503); response.end() })
    await expect(waitForHttp(unhealthy.url, { timeoutMs: 90, intervalMs: 10 })).rejects.toThrow('HTTP 503')
    const hanging = await httpServer(() => {})
    const controller = new AbortController()
    const startedAt = Date.now()
    const pending = waitForHttp(hanging.url, { timeoutMs: 5000, signal: controller.signal })
    setTimeout(() => controller.abort(), 30)
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    expect(Date.now() - startedAt).toBeLessThan(1000)
  })

  it('只启动被请求的服务，通知就绪，关闭后释放端口', async () => {
    const first = await fixture(80)
    const second = await fixture()
    second.service.id = 'second'
    const { pool, events } = supervised([first.service, second.service])
    await pool.start('fixture')
    expect(events).toEqual(['ready fixture'])
    // 重复请求复用已就绪的服务。
    await pool.start('fixture')
    expect(events).toEqual(['ready fixture'])
    await expect(assertPortsAvailable([second.service])).resolves.toBeUndefined()
    const pid = Number(await readFile(first.marker, 'utf8'))
    await pool.close()
    await expect(assertPortsAvailable([first.service])).resolves.toBeUndefined()
    expect(() => process.kill(pid, 0)).toThrow()
  })

  it('停止单个服务，其余服务继续运行', async () => {
    const first = await fixture()
    const second = await fixture()
    second.service.id = 'second'
    const { pool } = supervised([first.service, second.service])
    await Promise.all([pool.start('fixture'), pool.start('second')])
    await pool.stop('fixture')
    await expect(assertPortsAvailable([first.service])).resolves.toBeUndefined()
    expect(await (await fetch(second.service.url)).text()).toBe('fixture')
    // 停止后可以再次启动。
    await pool.start('fixture')
    expect(await (await fetch(first.service.url)).text()).toBe('fixture')
  })

  it('带预览令牌时传给子进程，并带 Cookie 检查就绪', async () => {
    const { service } = await fixture()
    const script = join(service.cwd, 'gated.mjs')
    await writeFile(script, `
import http from 'node:http'
const token = process.env.UI_ATLAS_PREVIEW_TOKEN
http.createServer((request, response) => {
  response.writeHead(token && request.headers.cookie === 'ui_atlas_preview=' + token ? 200 : 403)
  response.end()
}).listen(${service.port}, '127.0.0.1')`)
    service.command = [process.execPath, script]
    const { pool, events } = supervised([service], { previewToken: 'launch-token', timeoutMs: 5000 })
    await pool.start('fixture')
    expect(events).toEqual(['ready fixture'])
    expect((await fetch(service.url)).status).toBe(403)
  })

  it('拒绝未知作品', async () => {
    const { pool, events } = supervised([])
    await expect(pool.start('missing')).rejects.toThrow('missing')
    expect(events[0]).toContain('failed missing')
  })

  it('端口被占用时只让该服务失败，保留占用者', async () => {
    const occupied = await httpServer((_request, response) => response.end('existing'))
    const blocked = await fixture()
    blocked.service.port = occupied.port
    blocked.service.url = occupied.url
    const { pool, events } = supervised([blocked.service])
    await expect(pool.start('fixture')).rejects.toThrow(`端口 ${occupied.port}`)
    expect(events).toEqual([expect.stringContaining('failed fixture')])
    expect(await (await fetch(occupied.url)).text()).toBe('existing')
  })

  it('子进程的 HTTP 就绪检查始终未成功时将其清理，之后可以重试', async () => {
    const { service } = await fixture(10000)
    const { pool, events } = supervised([service], { timeoutMs: 250 })
    await expect(pool.start('fixture')).rejects.toThrow('启动超时')
    await expect(assertPortsAvailable([service])).resolves.toBeUndefined()
    service.command[4] = '0'
    await pool.start('fixture')
    expect(events.at(-1)).toBe('ready fixture')
  })

  it('服务在启动期间退出时立即报告失败', async () => {
    const failing = await fixture()
    failing.service.command = [process.execPath, '-e', 'setTimeout(() => process.exit(23), 120)']
    const startedAt = Date.now()
    const { pool } = supervised([failing.service], { timeoutMs: 5000 })
    await expect(pool.start('fixture')).rejects.toThrow('意外退出')
    expect(Date.now() - startedAt).toBeLessThan(2500)
  })

  it('已就绪的服务异常退出时报告失败并释放端口', async () => {
    const { service, marker } = await fixture()
    const { pool, events } = supervised([service])
    await pool.start('fixture')
    process.kill(Number(await readFile(marker, 'utf8')), 'SIGKILL')
    for (let count = 0; events.length < 2 && count < 100; count++) await delay(20)
    expect(events[1]).toContain('意外退出')
    await expect(assertPortsAvailable([service])).resolves.toBeUndefined()
  })

  it('清理整个进程组，包括忽略 TERM 信号的孙进程', async () => {
    const nested = await fixture(0, 'ignore')
    const parentScript = join(nested.service.cwd, 'parent.mjs')
    await writeFile(parentScript, `import { spawn } from 'node:child_process'; spawn(process.execPath, process.argv.slice(2), { stdio: 'ignore' }); process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`)
    nested.service.command = [process.execPath, parentScript, ...nested.service.command.slice(1)]
    const { pool } = supervised([nested.service])
    await pool.start('fixture')
    await pool.close()
    await expect(assertPortsAvailable([nested.service])).resolves.toBeUndefined()
  })
})
