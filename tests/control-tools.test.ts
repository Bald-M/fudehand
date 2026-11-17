import { afterEach, describe, expect, it } from 'vitest'
import net from 'node:net'
import { rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { callTool, tools } from '../scripts/atlas-tools.mjs'

const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

/** 假的 App 控制通道：记录收到的请求，用 respond 生成响应。 */
async function fakeApp(respond: (request: { id: unknown, command: string, args: Record<string, unknown> }) => object, { splitInside = '' } = {}) {
  const socketPath = join(tmpdir(), `uia-${randomUUID().slice(0, 8)}.sock`)
  const received: unknown[] = []
  const server = net.createServer(socket => {
    let buffer = ''
    socket.on('data', chunk => {
      buffer += chunk
      let index
      while ((index = buffer.indexOf('\n')) >= 0) {
        const request = JSON.parse(buffer.slice(0, index))
        buffer = buffer.slice(index + 1)
        received.push(request)
        const line = Buffer.from(JSON.stringify({ id: request.id, ...respond(request) }) + '\n')
        if (!splitInside) { socket.write(line); continue }
        const splitAt = line.indexOf(Buffer.from(splitInside)) + 1
        // 分两次写出，模拟数据块恰好切在多字节字符中间。
        socket.write(line.subarray(0, splitAt))
        setTimeout(() => socket.write(line.subarray(splitAt)), 20)
      }
    })
  })
  await new Promise<void>(resolve => server.listen(socketPath, resolve))
  cleanup.push(async () => { await new Promise(resolve => server.close(resolve)); await rm(socketPath, { force: true }) })
  return { socketPath, received }
}

const text = (result: { content: { text?: string }[] }) => result.content.map(item => item.text ?? '').join('\n')

describe('画布控制工具', () => {
  it('提供全部画布工具', () => {
    expect(tools.map((tool: { name: string }) => tool.name)).toEqual(expect.arrayContaining([
      'canvas_get_state', 'canvas_select_project', 'canvas_focus_frame', 'canvas_fit_all',
      'canvas_zoom', 'canvas_reset', 'canvas_restart_preview', 'frame_snapshot',
      'frame_console', 'frame_read', 'frame_interact',
    ]))
  })

  it('把命令和参数转发给 App 并返回结果', async () => {
    const app = await fakeApp(request => ({ ok: true, result: { project: 'still', echo: request.command } }))
    const ctx = { root: '/unused', socketPath: app.socketPath }
    const focused = await callTool('canvas_focus_frame', { frame: 'mobile' }, ctx)
    expect(focused.isError).toBeFalsy()
    expect(JSON.parse(text(focused))).toEqual({ project: 'still', echo: 'focus_frame' })
    await callTool('canvas_select_project', { project: 'form' }, ctx)
    await callTool('canvas_zoom', { scale: 0.5 }, ctx)
    await callTool('canvas_fit_all', {}, ctx)
    await callTool('canvas_reset', {}, ctx)
    await callTool('canvas_restart_preview', {}, ctx)
    await callTool('canvas_get_state', {}, ctx)
    expect(app.received.map(request => {
      const { command, args } = request as { command: string, args: object }
      return { command, args }
    })).toEqual([
      { command: 'focus_frame', args: { frame: 'mobile' } },
      { command: 'select_project', args: { project: 'form' } },
      { command: 'zoom', args: { scale: 0.5 } },
      { command: 'fit_all', args: {} },
      { command: 'reset', args: {} },
      { command: 'restart_preview', args: {} },
      { command: 'get_state', args: {} },
    ])
  })

  it('透传 App 返回的中文错误', async () => {
    const app = await fakeApp(() => ({ ok: false, error: '当前作品没有画框：tv' }))
    const result = await callTool('canvas_focus_frame', { frame: 'tv' }, { root: '/unused', socketPath: app.socketPath })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('当前作品没有画框：tv')
  })

  it('App 未运行时返回“ui-atlas 未运行”', async () => {
    const socketPath = join(tmpdir(), `uia-missing-${randomUUID().slice(0, 8)}.sock`)
    const result = await callTool('canvas_get_state', {}, { root: '/unused', socketPath })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('ui-atlas 未运行')
  })

  it('frame_snapshot 以 MCP image 内容返回截图', async () => {
    const app = await fakeApp(() => ({ ok: true, result: { frame: 'mobile', mimeType: 'image/png', data: 'iVBORw0KGgo=', width: 390, height: 844 } }))
    const result = await callTool('frame_snapshot', { frame: 'mobile' }, { root: '/unused', socketPath: app.socketPath })
    expect(result.isError).toBeFalsy()
    expect(result.content).toEqual([
      { type: 'image', data: 'iVBORw0KGgo=', mimeType: 'image/png' },
      { type: 'text', text: '画框 mobile 的截图（390×844）' },
    ])
  })

  it('转发画框控制台与交互命令，只传定义过的参数', async () => {
    const app = await fakeApp(request => ({ ok: true, result: { frame: 'web', echo: request.command } }))
    const ctx = { root: '/unused', socketPath: app.socketPath }
    expect((await callTool('frame_console', { frame: 'web' }, ctx)).isError).toBeFalsy()
    await callTool('frame_console', { frame: 'web', limit: 20 }, ctx)
    await callTool('frame_interact', { frame: 'web', action: 'fill', selector: '#q', value: '猫', extra: 1 }, ctx)
    await callTool('frame_interact', { frame: 'web', action: 'scroll', deltaY: 400 }, ctx)
    expect(app.received.map(request => (request as { args: object }).args)).toEqual([
      { frame: 'web' },
      { frame: 'web', limit: 20 },
      { frame: 'web', action: 'fill', selector: '#q', value: '猫' },
      { frame: 'web', action: 'scroll', deltaY: 400 },
    ])
  })

  it('frame_read 以文本大纲返回页面内容', async () => {
    const app = await fakeApp(() => ({ ok: true, result: { frame: 'web', url: 'http://127.0.0.1:4401/', title: '首页', outline: 'h1 你好\nbutton "提交" → #go', truncated: true } }))
    const result = await callTool('frame_read', { frame: 'web' }, { root: '/unused', socketPath: app.socketPath })
    expect(result.isError).toBeFalsy()
    expect(text(result)).toBe('首页\nhttp://127.0.0.1:4401/\n\nh1 你好\nbutton "提交" → #go\n\n（内容过长，已截断）')
  })

  it('响应跨数据块且切在中文字符中间时仍完整解析', async () => {
    const error = '当前作品没有画框：手机'
    const app = await fakeApp(() => ({ ok: false, error }), { splitInside: '没' })
    const result = await callTool('canvas_focus_frame', { frame: '手机' }, { root: '/unused', socketPath: app.socketPath })
    expect(text(result)).toBe(error)
  })

  it('读取数 MB 的截图响应', async () => {
    const data = 'A'.repeat(6 << 20)
    const app = await fakeApp(() => ({ ok: true, result: { frame: 'web', mimeType: 'image/png', data, width: 1440, height: 900 } }))
    const result = await callTool('frame_snapshot', { frame: 'web' }, { root: '/unused', socketPath: app.socketPath })
    expect(result.content[0].data.length).toBe(data.length)
  })
})
