import { afterEach, describe, expect, it } from 'vitest'
import { createServer, type RequestListener } from 'node:http'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { assertPortsAvailable, runServices, servicesFromCatalog, waitForHttp } from '../scripts/launcher.mjs'

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
  if (!address || typeof address === 'string') throw new Error('No test port')
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
  if (!address || typeof address === 'string') throw new Error('No test port')
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
    service: { id: 'fixture', title: 'Fixture', cwd, command: [process.execPath, script, String(port), marker, String(wait), mode], port, url: `http://127.0.0.1:${port}/` },
  }
}

function supervised(services: object[], options: Record<string, unknown> = {}) {
  const controller = new AbortController()
  const result = runServices(services, { signal: controller.signal, stdio: 'ignore', log: () => {}, shutdownGraceMs: 100, ...options })
  // Attach a handler immediately: assertions may first wait for fixture readiness.
  void result.catch(() => {})
  cleanup.push(async () => { controller.abort(); await result.catch(() => {}) })
  return { controller, result }
}

async function fixtureCatalog() {
  const cwd = await tempDirectory()
  await mkdir(join(cwd, 'apps/atlas'), { recursive: true })
  await mkdir(join(cwd, 'examples/demo'), { recursive: true })
  return { cwd, catalog: {
    version: 1,
    shell: { port: 31001, url: 'http://127.0.0.1:31001/' },
    projects: [{ id: 'demo', title: 'Demo', subtitle: '', description: '', author: 'Original', sourceUrl: null as string | null, framework: 'HTML', tags: ['demo'], enabled: true, layoutVersion: 1,
      preview: { cwd: 'examples/demo', command: [process.execPath, 'dev.mjs'], port: 31002, baseUrl: 'http://127.0.0.1:31002/demo/' },
      frames: [{ id: 'home', title: 'Home', platform: 'web', path: 'home', width: 1440, height: 900, x: 0, y: 0 }],
    }],
  } }
}

describe('catalog and local services', () => {
  it('keeps enabled projects independent and supports an empty gallery', async () => {
    const { cwd, catalog } = await fixtureCatalog()
    const services = await servicesFromCatalog(catalog, cwd)
    expect(services.map((service: { id: string }) => service.id)).toEqual(['atlas', 'demo'])
    expect(services[1].cwd).toBe(join(cwd, 'examples/demo'))
    catalog.projects[0].enabled = false
    expect(await servicesFromCatalog(catalog, cwd)).toHaveLength(1)
    catalog.projects = []
    expect(await servicesFromCatalog(catalog, cwd)).toHaveLength(1)
  })

  it('rejects duplicate ports, off-machine URLs, invalid geometry and escaping directories', async () => {
    const { cwd, catalog } = await fixtureCatalog()
    const duplicate = structuredClone(catalog)
    duplicate.projects[0].preview.port = 31001
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

  it('reports an occupied port without disturbing its existing server', async () => {
    const occupied = await httpServer((_request, response) => response.end('existing'))
    const service = { title: 'Already running', port: occupied.port, url: occupied.url }
    await expect(assertPortsAvailable([service])).rejects.toThrow(`端口 ${occupied.port}`)
    expect(await (await fetch(occupied.url)).text()).toBe('existing')
  })

  it('waits for HTTP success, not just an open socket', async () => {
    const readyAt = Date.now() + 120
    const endpoint = await httpServer((_request, response) => { response.writeHead(Date.now() < readyAt ? 503 : 200); response.end() })
    await waitForHttp(endpoint.url, { timeoutMs: 1000, intervalMs: 15 })
    expect(Date.now()).toBeGreaterThanOrEqual(readyAt)
  })

  it('times out unhealthy HTTP and cancels a pending request promptly', async () => {
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

  it('starts a real child, announces readiness and releases its port on stop', async () => {
    const { service, marker } = await fixture(80)
    let ready = false
    const { controller, result } = supervised([service], { onReady: () => { ready = true } })
    await waitForHttp(service.url, { timeoutMs: 5000, intervalMs: 20 })
    for (let count = 0; !ready && count < 30; count++) await delay(20)
    expect(ready).toBe(true)
    const pid = Number(await readFile(marker, 'utf8'))
    controller.abort()
    await expect(result).resolves.toBeUndefined()
    await expect(assertPortsAvailable([service])).resolves.toBeUndefined()
    expect(() => process.kill(pid, 0)).toThrow()
  })

  it('cleans up a child when its HTTP readiness never becomes successful', async () => {
    const { service } = await fixture(10000)
    const { result } = supervised([service], { timeoutMs: 250 })
    await expect(result).rejects.toThrow('启动超时')
    await expect(assertPortsAvailable([service])).resolves.toBeUndefined()
  })

  it('cancels other HTTP waits immediately if one service exits', async () => {
    const healthy = await fixture()
    const failing = await fixture()
    failing.service.command = [process.execPath, '-e', 'setTimeout(() => process.exit(23), 120)']
    failing.service.id = 'failing'
    failing.service.title = 'Failing fixture'
    const startedAt = Date.now()
    const { result } = supervised([healthy.service, failing.service], { timeoutMs: 5000 })
    await expect(result).rejects.toThrow('意外退出')
    expect(Date.now() - startedAt).toBeLessThan(2500)
    await expect(assertPortsAvailable([healthy.service])).resolves.toBeUndefined()
  })

  it('cleans the full process group, including a grandchild that ignores TERM', async () => {
    const nested = await fixture(0, 'ignore')
    const parentScript = join(nested.service.cwd, 'parent.mjs')
    await writeFile(parentScript, `import { spawn } from 'node:child_process'; spawn(process.execPath, process.argv.slice(2), { stdio: 'ignore' }); process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`)
    nested.service.command = [process.execPath, parentScript, ...nested.service.command.slice(1)]
    const { controller, result } = supervised([nested.service])
    await waitForHttp(nested.service.url, { timeoutMs: 5000, intervalMs: 20 })
    controller.abort()
    await expect(result).resolves.toBeUndefined()
    await expect(assertPortsAvailable([nested.service])).resolves.toBeUndefined()
  })
})
