import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { callTool, tools } from '../scripts/atlas-tools.mjs'
import { fakeApp } from './helpers/fake-app'

const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

async function app(respond: Parameters<typeof fakeApp>[0], options?: Parameters<typeof fakeApp>[1]) {
  const result = await fakeApp(respond, options)
  cleanup.push(result.close)
  return result
}

const text = (result: { content: { text?: string }[] }) => result.content.map(item => item.text ?? '').join('\n')
const echo = (request: { command: string }) => ({ ok: true, result: { echo: request.command } })
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

describe('设计工具', () => {
  it('提供全部设计与画布工具，不再有作品与网页工具', () => {
    const names = tools.map((tool: { name: string }) => tool.name)
    expect(names).toEqual([
      'design_get_state', 'design_get_document', 'design_get_node', 'design_create_node', 'design_update_node',
      'design_delete_nodes', 'design_move_node', 'design_select', 'design_undo', 'design_redo',
      'design_new_document', 'design_open_document', 'design_save_document',
      'canvas_focus_node', 'canvas_fit_all', 'canvas_zoom', 'design_snapshot',
    ])
    for (const tool of tools as { inputSchema: { type: string } }[]) expect(tool.inputSchema.type).toBe('object')
  })

  it('把命令和定义过的参数转发给 App', async () => {
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    const created = await callTool('design_create_node', { parent: 'f', node: { type: 'rectangle', fill: '#FFFFFF' }, extra: 1 }, ctx)
    expect(created.isError).toBeFalsy()
    expect(JSON.parse(text(created))).toEqual({ echo: 'create_node' })
    await callTool('design_update_node', { id: 'a', changes: { opacity: 0.5 } }, ctx)
    await callTool('design_delete_nodes', { ids: ['a', 'b'] }, ctx)
    await callTool('design_move_node', { id: 'a', index: 0 }, ctx)
    await callTool('design_select', { ids: [] }, ctx)
    await callTool('design_undo', {}, ctx)
    await callTool('design_new_document', { discard: true }, ctx)
    await callTool('design_open_document', { path: 'designs/home.uiatlas' }, ctx)
    await callTool('design_save_document', {}, ctx)
    await callTool('design_save_document', { path: '/tmp/a.uiatlas' }, ctx)
    await callTool('canvas_zoom', { scale: 0.5 }, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'create_node', args: { node: { type: 'rectangle', fill: '#FFFFFF' }, parent: 'f' } },
      { command: 'update_node', args: { id: 'a', changes: { opacity: 0.5 } } },
      { command: 'delete_nodes', args: { ids: ['a', 'b'] } },
      { command: 'move_node', args: { id: 'a', index: 0 } },
      { command: 'select', args: { ids: [] } },
      { command: 'undo', args: {} },
      { command: 'new_document', args: { discard: true } },
      { command: 'open_document', args: { path: '/repo/designs/home.uiatlas' } },
      { command: 'save_document', args: {} },
      { command: 'save_document', args: { path: '/tmp/a.uiatlas' } },
      { command: 'zoom', args: { scale: 0.5 } },
    ])
  })

  it('把 image.path 读成 base64，包括子图层与修改', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'uia-image-'))
    cleanup.push(() => rm(dir, { recursive: true, force: true }))
    await writeFile(join(dir, 'dot.png'), Buffer.from(PNG, 'base64'))
    const fake = await app(echo)
    const ctx = { root: dir, socketPath: fake.socketPath }
    await callTool('design_create_node', { node: { type: 'frame', children: [{ type: 'image', image: { path: 'dot.png', fit: 'fit' } }] } }, ctx)
    await callTool('design_update_node', { id: 'i', changes: { image: { path: join(dir, 'dot.png') } } }, ctx)
    expect(fake.received[0].args.node).toEqual({ type: 'frame', children: [{ type: 'image', image: { data: PNG, fit: 'fit' } }] })
    expect(fake.received[1].args.changes).toEqual({ image: { data: PNG } })
    const missing = await callTool('design_create_node', { node: { type: 'image', image: { path: 'nope.png' } } }, ctx)
    expect(missing.isError).toBe(true)
    expect(text(missing)).toBe('无法读取图片：nope.png')
    expect(fake.received).toHaveLength(2)
  })

  it('透传 App 返回的中文错误', async () => {
    const fake = await app(() => ({ ok: false, error: '图层 e：ellipse 不支持 layout' }))
    const result = await callTool('design_update_node', { id: 'e', changes: { layout: {} } }, { root: '/repo', socketPath: fake.socketPath })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('图层 e：ellipse 不支持 layout')
  })

  it('App 未运行时返回“ui-atlas 未运行”', async () => {
    const socketPath = join(tmpdir(), `uia-missing-${randomUUID().slice(0, 8)}.sock`)
    const result = await callTool('design_get_state', {}, { root: '/repo', socketPath })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('ui-atlas 未运行')
  })

  it('design_snapshot 以 MCP image 内容返回截图', async () => {
    const fake = await app(() => ({ ok: true, result: { id: 'home', mimeType: 'image/png', data: PNG, width: 390, height: 844 } }))
    const result = await callTool('design_snapshot', { id: 'home' }, { root: '/repo', socketPath: fake.socketPath })
    expect(fake.received[0]).toMatchObject({ command: 'node_snapshot', args: { id: 'home' } })
    expect(result.content).toEqual([
      { type: 'image', data: PNG, mimeType: 'image/png' },
      { type: 'text', text: '图层 home 的截图（390×844）' },
    ])
  })

  it('响应跨数据块且切在中文字符中间时仍完整解析', async () => {
    const error = '找不到图层：手机'
    const fake = await app(() => ({ ok: false, error }), { splitInside: '图' })
    const result = await callTool('design_get_node', { id: '手机' }, { root: '/repo', socketPath: fake.socketPath })
    expect(text(result)).toBe(error)
  })

  it('读取数 MB 的截图响应', async () => {
    const data = 'A'.repeat(6 << 20)
    const fake = await app(() => ({ ok: true, result: { id: 'web', mimeType: 'image/png', data, width: 1440, height: 900 } }))
    const result = await callTool('design_snapshot', { id: 'web' }, { root: '/repo', socketPath: fake.socketPath })
    expect(result.content[0].data.length).toBe(data.length)
  })
})
