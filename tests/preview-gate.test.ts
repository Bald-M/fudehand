import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createServer, type ViteDevServer } from 'vite'
import { PREVIEW_COOKIE, previewGate } from '../scripts/preview-gate.mjs'

const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

async function devServer(token: string | undefined) {
  const root = await mkdtemp(join(tmpdir(), 'ui-atlas-gate-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  await writeFile(join(root, 'index.html'), '<!doctype html><title>作品</title><script type="module" src="/main.js"></script>')
  await writeFile(join(root, 'main.js'), 'document.title = "作品"')
  const server: ViteDevServer = await createServer({
    root, configFile: false, logLevel: 'silent', plugins: [previewGate(token)],
    server: { host: '127.0.0.1', port: 0, ws: false },
  })
  await server.listen()
  cleanup.push(() => server.close())
  const address = server.httpServer?.address()
  if (!address || typeof address === 'string') throw new Error('未获得测试端口')
  return `http://127.0.0.1:${address.port}`
}

describe('预览令牌', () => {
  it('没有或带错 Cookie 的请求一律返回 403，不泄露作品内容', async () => {
    const base = await devServer('secret-token')
    for (const path of ['/', '/main.js', '/@vite/client']) {
      const plain = await fetch(base + path)
      expect(plain.status).toBe(403)
      expect(await plain.text()).toContain('ui-atlas')
      const wrong = await fetch(base + path, { headers: { cookie: `${PREVIEW_COOKIE}=other` } })
      expect(wrong.status).toBe(403)
    }
  })

  it('带正确 Cookie 的页面、子资源和 Vite 客户端正常返回', async () => {
    const base = await devServer('secret-token')
    const cookie = `theme=dark; ${PREVIEW_COOKIE}=secret-token`
    const page = await fetch(base + '/', { headers: { cookie } })
    expect(page.status).toBe(200)
    expect(await page.text()).toContain('作品')
    expect((await fetch(base + '/main.js', { headers: { cookie } })).status).toBe(200)
    expect((await fetch(base + '/@vite/client', { headers: { cookie } })).status).toBe(200)
  })

  it('不经 App 启动（没有令牌）时不拦截', async () => {
    const base = await devServer(undefined)
    expect((await fetch(base + '/')).status).toBe(200)
  })
})
