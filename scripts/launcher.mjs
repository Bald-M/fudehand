import { spawn } from 'node:child_process'
import { readFile, realpath, stat } from 'node:fs/promises'
import net from 'node:net'
import { isAbsolute, relative, resolve, sep } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { PREVIEW_COOKIE, PREVIEW_TOKEN_ENV } from './preview-gate.mjs'

function requireValue(condition, message) {
  if (!condition) throw new Error(`配置错误：${message}`)
}

function localUrl(value, port, name) {
  let url
  try { url = new URL(value) } catch { throw new Error(`配置错误：${name} 必须是有效 URL`) }
  requireValue(url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname), `${name} 只能使用本机 HTTP 地址`)
  requireValue(!url.username && !url.password && Number(url.port || 80) === port, `${name} 的端口必须与 port 一致，且不能包含账号信息`)
  return url
}

function requirePort(port, name, ports) {
  requireValue(Number.isInteger(port) && port > 0 && port <= 65535, `${name} 必须是 1～65535 的整数`)
  requireValue(!ports.has(port), `端口 ${port} 重复，请为每个服务设置独立端口`)
  ports.add(port)
}

async function directory(root, cwd, name) {
  requireValue(typeof cwd === 'string' && cwd.length > 0 && !isAbsolute(cwd), `${name} 必须是项目内的相对目录`)
  const inside = (base, path) => {
    const part = relative(base, path)
    return part !== '..' && !part.startsWith(`..${sep}`) && !isAbsolute(part)
  }
  const absolute = resolve(root, cwd)
  requireValue(inside(root, absolute), `${name} 不能离开项目目录`)
  let real
  try { real = await realpath(absolute) } catch { throw new Error(`配置错误：${name} 目录不存在：${cwd}`) }
  // 符号链接可能指向项目外，按真实路径再检查一次。
  requireValue(inside(await realpath(root), real), `${name} 不能离开项目目录`)
  requireValue((await stat(real)).isDirectory(), `${name} 不是目录：${cwd}`)
  return absolute
}

/** 原生 App 与案例启动器共用 catalog.json，运行状态不覆盖这份权威配置。返回已启用案例的服务。 */
export async function servicesFromCatalog(catalog, root) {
  requireValue(catalog && catalog.version === 1, 'catalog.version 必须是 1')
  requireValue(Array.isArray(catalog.projects), '需要 projects 数组')
  const ports = new Set()
  const services = []
  const ids = new Set()
  for (const project of catalog.projects) {
    requireValue(project && typeof project.id === 'string' && /^[a-z0-9][a-z0-9-]*$/.test(project.id) && !ids.has(project.id), '作品 id 必须唯一，且仅使用小写字母、数字或连字符')
    ids.add(project.id)
    const name = project.id
    requireValue(typeof project.title === 'string' && project.title.trim(), `${name}.title 不能为空`)
    for (const key of ['subtitle', 'description', 'author', 'framework']) requireValue(typeof project[key] === 'string', `${name}.${key} 必须是字符串`)
    requireValue(Array.isArray(project.tags) && project.tags.every(tag => typeof tag === 'string'), `${name}.tags 必须是字符串数组`)
    if (project.sourceUrl !== null) {
      let source
      try { source = new URL(project.sourceUrl) } catch { throw new Error(`配置错误：${name}.sourceUrl 必须是 HTTP/HTTPS 地址或 null`) }
      requireValue(['http:', 'https:'].includes(source.protocol), `${name}.sourceUrl 必须是 HTTP/HTTPS 地址或 null`)
    }
    requireValue(typeof project.enabled === 'boolean', `${name}.enabled 必须是布尔值`)
    requireValue(Number.isInteger(project.layoutVersion) && project.layoutVersion > 0, `${name}.layoutVersion 必须是正整数`)
    const preview = project.preview
    requireValue(preview && typeof preview === 'object', `${name} 缺少 preview`)
    requirePort(preview.port, `${name}.preview.port`, ports)
    const base = localUrl(preview.baseUrl, preview.port, `${name}.preview.baseUrl`)
    const cwd = await directory(root, preview.cwd, `${name}.preview.cwd`)
    requireValue(Array.isArray(preview.command) && preview.command.length > 0 && preview.command.every(item => typeof item === 'string' && item.length > 0 && !item.includes('\0')), `${name}.preview.command 必须是非空参数数组`)
    requireValue(Array.isArray(project.frames) && project.frames.length > 0, `${name} 至少需要一个画框`)
    const frameIds = new Set()
    for (const frame of project.frames) {
      requireValue(frame && typeof frame.id === 'string' && frame.id.length > 0 && !frameIds.has(frame.id), `${name} 的画框 id 必须非空且唯一`)
      frameIds.add(frame.id)
      requireValue(typeof frame.title === 'string' && frame.title.trim(), `${name}/${frame.id}.title 不能为空`)
      requireValue(['mobile', 'web', 'desktop'].includes(frame.platform), `${name}/${frame.id}.platform 必须是 mobile、web 或 desktop`)
      requireValue(['width', 'height'].every(key => Number.isFinite(frame[key]) && frame[key] > 0), `${name}/${frame.id} 的宽高必须是有限正数`)
      requireValue(['x', 'y'].every(key => Number.isFinite(frame[key])), `${name}/${frame.id} 的坐标必须是有限数值`)
      requireValue(typeof frame.path === 'string' && frame.path.length > 0, `${name}/${frame.id}.path 不能为空`)
      let frameUrl
      try { frameUrl = new URL(frame.path, base) } catch { throw new Error(`配置错误：${name}/${frame.id}.path 无法解析`) }
      requireValue(frameUrl.origin === base.origin && !frameUrl.username && !frameUrl.password, `${name}/${frame.id}.path 必须指向该作品的本地预览服务`)
    }
    if (project.enabled) services.push({ id: project.id, title: project.title, cwd, command: preview.command, port: preview.port, url: preview.baseUrl })
  }
  return services
}

export async function readServices(root) {
  const catalog = JSON.parse(await readFile(resolve(root, 'catalog.json'), 'utf8'))
  return servicesFromCatalog(catalog, root)
}

export async function assertPortsAvailable(services) {
  for (const service of services) {
    const hostname = new URL(service.url).hostname.replace(/^\[|\]$/g, '')
    await new Promise((resolveAvailable, reject) => {
      const server = net.createServer()
      server.once('error', error => reject(new Error(`${service.title} 的端口 ${service.port} 无法使用（${error.code}）。请关闭占用程序或同步修改配置和该案例的启动端口。`)))
      server.listen({ host: hostname, port: service.port, exclusive: true }, () => server.close(resolveAvailable))
    })
  }
}

export async function waitForHttp(url, { timeoutMs = 30000, intervalMs = 100, signal, headers } = {}) {
  const deadline = Date.now() + timeoutMs
  let lastStatus = '尚未响应'
  while (Date.now() < deadline) {
    signal?.throwIfAborted()
    try {
      const requestSignal = AbortSignal.timeout(Math.max(1, Math.min(1000, deadline - Date.now())))
      const response = await fetch(url, { headers, signal: signal ? AbortSignal.any([signal, requestSignal]) : requestSignal })
      lastStatus = `HTTP ${response.status}`
      await response.body?.cancel()
      if (response.ok) return
    } catch (error) {
      signal?.throwIfAborted()
      lastStatus = error instanceof Error ? error.message : String(error)
    }
    await delay(Math.min(intervalMs, Math.max(1, deadline - Date.now())), undefined, { signal })
  }
  throw new Error(`预览启动超时（${timeoutMs}ms）：${url}；最后状态：${lastStatus}`)
}

function groupExists(child) {
  if (!child.pid) return false
  try { process.kill(process.platform === 'win32' ? child.pid : -child.pid, 0); return true } catch { return false }
}

function signalGroup(child, signal) {
  if (!child.pid) return
  try {
    if (process.platform === 'win32') child.kill(signal)
    else process.kill(-child.pid, signal)
  } catch (error) {
    if (error.code !== 'ESRCH') throw error
  }
}

/** 只向本次启动的进程组发送信号，同时清理包管理器遗留的孙进程。 */
async function stopGroups(children, graceMs) {
  for (const child of children) signalGroup(child, 'SIGTERM')
  const deadline = Date.now() + graceMs
  while (Date.now() < deadline && children.some(groupExists)) await delay(30)
  for (const child of children) if (groupExists(child)) signalGroup(child, 'SIGKILL')
  // A direct child can exit before its grandchildren release their sockets.
  const forceDeadline = Date.now() + 1000
  while (Date.now() < forceDeadline && children.some(groupExists)) await delay(20)
  await Promise.all(children.filter(child => child.pid && child.exitCode === null && child.signalCode === null).map(child =>
    Promise.race([new Promise(resolveExit => child.once('exit', resolveExit)), delay(1000)]),
  ))
}

/**
 * 按需启动案例服务：start(id) 拉起并等待 HTTP 就绪，重复请求复用同一次启动；
 * 失败或意外退出只影响该服务，并清理它的进程组，之后可以再次 start。close() 停止全部服务。
 */
export function createServicePool(services, { timeoutMs = 30000, shutdownGraceMs = 1500, stdio = 'inherit', log = console.log, onReady = () => {}, onFailed = () => {}, previewToken = process.env[PREVIEW_TOKEN_ENV] } = {}) {
  // previewToken 来自 App（见 preview-gate.mjs）：传给每个案例服务，就绪检查也带上对应 Cookie。
  const env = previewToken ? { ...process.env, [PREVIEW_TOKEN_ENV]: previewToken } : process.env
  const headers = previewToken ? { cookie: `${PREVIEW_COOKIE}=${previewToken}` } : undefined
  const byId = new Map(services.map(service => [service.id, service]))
  const running = new Map()
  let closed = false

  async function launch(service, entry) {
    await assertPortsAvailable([service])
    if (entry.abort.signal.aborted) throw entry.failure ?? new Error(`${service.title} 已停止`)
    log(`[启动] ${service.title} → ${service.url}`)
    const child = spawn(service.command[0], service.command.slice(1), {
      cwd: service.cwd, stdio, env, detached: process.platform !== 'win32', shell: false,
    })
    entry.child = child
    child.once('error', error => fail(entry, new Error(`${service.title} 无法启动：${error.message}`)))
    child.once('exit', (code, exitSignal) => fail(entry, new Error(`${service.title} 意外退出（${exitSignal || code}）。`)))
    try {
      await waitForHttp(service.url, { timeoutMs, signal: entry.abort.signal, headers })
    } catch (error) {
      throw entry.failure ?? error
    }
  }

  function fail(entry, error) {
    if (entry.stopping || entry.failure) return
    entry.failure = error
    entry.abort.abort()
    // 已就绪的服务没有等待中的启动流程，在这里收尾。
    if (entry.ready) void settleFailure(entry)
  }

  async function settleFailure(entry) {
    if (running.get(entry.service.id) === entry) running.delete(entry.service.id)
    if (entry.child) await stopGroups([entry.child], shutdownGraceMs)
    onFailed(entry.service.id, entry.failure)
  }

  function start(id) {
    const service = byId.get(id)
    if (!service || closed) {
      const error = new Error(closed ? '启动器正在退出' : `找不到已启用的作品：${id}`)
      onFailed(id, error)
      return Promise.reject(error)
    }
    const existing = running.get(id)
    if (existing) return existing.promise
    const entry = { service, abort: new AbortController(), child: null, ready: false, stopping: false, failure: null }
    running.set(id, entry)
    entry.promise = launch(service, entry).then(() => {
      entry.ready = true
      onReady(id)
    }, async error => {
      if (entry.stopping) throw error
      entry.failure ??= error
      await settleFailure(entry)
      throw entry.failure
    })
    return entry.promise
  }

  async function stopEntry(entry) {
    entry.stopping = true
    entry.abort.abort()
    if (running.get(entry.service.id) === entry) running.delete(entry.service.id)
    await entry.promise.catch(() => {})
    if (entry.child) await stopGroups([entry.child], shutdownGraceMs)
  }

  return {
    start,
    async stop(id) {
      const entry = running.get(id)
      if (entry) await stopEntry(entry)
    },
    async close() {
      closed = true
      await Promise.all([...running.values()].map(stopEntry))
    },
  }
}
