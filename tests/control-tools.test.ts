import { afterEach, describe, expect, it, vi } from 'vitest'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { callTool, tools } from '../scripts/fudehand-tools.mjs'
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

describe('design tools', () => {
  it('provides all design and canvas tools, with no work or web tools left', () => {
    const names = tools.map((tool: { name: string }) => tool.name)
    expect(names).toEqual([
      'design_get_state', 'design_get_document', 'design_get_node', 'design_create_node', 'design_update_node',
      'design_delete_nodes', 'design_move_node', 'design_select', 'design_undo', 'design_redo',
      'design_new_document', 'design_open_document', 'design_save_document',
      'canvas_focus_node', 'canvas_fit_all', 'canvas_zoom', 'design_list_fonts', 'design_import_font', 'design_search_icons', 'design_snapshot',
      'style_list', 'style_read',
    ])
    for (const tool of tools as { inputSchema: { type: string } }[]) expect(tool.inputSchema.type).toBe('object')
  })

  it('describes interactions and forwards them to the App unchanged', async () => {
    const byName = (name: string) => (tools as { name: string, description: string }[]).find(tool => tool.name === name)!
    for (const field of ['interaction', 'navigate', 'back', 'destination', 'push-left', 'sheet', 'ease-in-out'])
      expect(byName('design_create_node').description).toContain(field)
    expect(byName('design_update_node').description).toContain('interaction, animation, states, effects, and text.sequence are replaced whole')
    const fake = await app(echo)
    const interaction = { action: 'navigate', destination: 'detail', transition: { type: 'push-left', duration: 0.3 } }
    await callTool('design_update_node', { id: 'a', changes: { interaction } }, { root: '/repo', socketPath: fake.socketPath })
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'update_node', args: { id: 'a', changes: { interaction } } },
    ])
    await fake.close()
  })

  it('describes in-screen interactions and forwards them to the App unchanged', async () => {
    const byName = (name: string) => (tools as { name: string, description: string }[]).find(tool => tool.name === name)!
    for (const field of ['open-overlay', 'close-overlay', 'toggle-visibility', 'targets', 'below-trigger', 'closeOnOutsideClick',
      'background', 'scroll', 'vertical', 'horizontal', 'fixedOnScroll', 'states', 'hover', 'pressed'])
      expect(byName('design_create_node').description).toContain(field)
    expect(byName('design_update_node').description).toContain('interaction, animation, states, effects, and text.sequence are replaced whole')
    const fake = await app(echo)
    const changes = {
      scroll: 'vertical',
      states: { hover: { fill: '#EEEEEE' }, pressed: { opacity: 0.6 } },
      interaction: { action: 'open-overlay', destination: 'menu', position: 'below-trigger', background: '#00000066', closeOnOutsideClick: false },
    }
    await callTool('design_update_node', { id: 'a', changes }, { root: '/repo', socketPath: fake.socketPath })
    await callTool('design_update_node', { id: 'b', changes: { fixedOnScroll: true, interaction: { action: 'toggle-visibility', targets: ['x', 'y'] } } },
      { root: '/repo', socketPath: fake.socketPath })
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'update_node', args: { id: 'a', changes } },
      { command: 'update_node', args: { id: 'b', changes: { fixedOnScroll: true, interaction: { action: 'toggle-visibility', targets: ['x', 'y'] } } } },
    ])
    await fake.close()
  })

  it('describes effects and forwards them unchanged', async () => {
    const byName = (name: string) => (tools as { name: string, description: string }[]).find(tool => tool.name === name)!
    for (const field of ['effects', 'drop-shadow', 'inner-shadow', 'layer-blur', 'background-blur', 'radius', 'spread', '#00000040'])
      expect(byName('design_create_node').description).toContain(field)
    const fake = await app(echo)
    const changes = { effects: [{ type: 'drop-shadow', color: '#00000033', x: 0, y: 8, radius: 24, spread: -4 }, { type: 'background-blur', radius: 20 }] }
    await callTool('design_update_node', { id: 'a', changes }, { root: '/repo', socketPath: fake.socketPath })
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([{ command: 'update_node', args: { id: 'a', changes } }])
    await fake.close()
  })

  it('describes animations and text sequences and forwards them unchanged', async () => {
    const byName = (name: string) => (tools as { name: string, description: string }[]).find(tool => tool.name === name)!
    for (const field of ['animation', 'fade-in', 'slide-in', 'scale-in', 'spin', 'pulse', 'shimmer', 'delay', 'repeat', '"infinite"', 'text.sequence', 'interval', 'loop'])
      expect(byName('design_create_node').description).toContain(field)
    expect(byName('design_update_node').description).toContain('interaction, animation, states, effects, and text.sequence are replaced whole')
    const fake = await app(echo)
    const changes = { animation: { type: 'pulse', property: 'opacity', repeat: 'infinite' }, text: { sequence: { items: ['3', '2', '1'] } } }
    await callTool('design_update_node', { id: 'a', changes }, { root: '/repo', socketPath: fake.socketPath })
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([{ command: 'update_node', args: { id: 'a', changes } }])
    await fake.close()
  })

  it('describes icon layers and searches icons through the App', async () => {
    const byName = (name: string) => (tools as { name: string, description: string, inputSchema: any }[]).find(tool => tool.name === name)!
    for (const field of ['icon', 'design_search_icons', '24×24'])
      expect(byName('design_create_node').description).toContain(field)
    const search = byName('design_search_icons')
    for (const field of ['sf', 'material-rounded', 'weui', 'lucide', 'Android', 'mini program'])
      expect(search.description).toContain(field)
    expect(search.inputSchema.required).toEqual(['query'])
    expect(search.inputSchema.properties.library.enum).toEqual(['sf', 'material-outlined', 'material-rounded', 'material-sharp', 'weui', 'lucide'])
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    await callTool('design_search_icons', { query: 'home' }, ctx)
    await callTool('design_search_icons', { query: 'home', library: 'lucide', limit: 5 }, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'search_icons', args: { query: 'home' } },
      { command: 'search_icons', args: { query: 'home', library: 'lucide', limit: 5 } },
    ])
  })

  it('forwards the command and the defined arguments to the App', async () => {
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
    await callTool('design_open_document', { path: 'designs/home.fudehand' }, ctx)
    await callTool('design_save_document', {}, ctx)
    await callTool('design_save_document', { path: '/tmp/a.fudehand' }, ctx)
    await callTool('canvas_zoom', { scale: 0.5 }, ctx)
    await callTool('design_list_fonts', {}, ctx)
    await callTool('design_import_font', { path: 'fonts/Brand.otf' }, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'create_node', args: { node: { type: 'rectangle', fill: '#FFFFFF' }, parent: 'f' } },
      { command: 'update_node', args: { id: 'a', changes: { opacity: 0.5 } } },
      { command: 'delete_nodes', args: { ids: ['a', 'b'] } },
      { command: 'move_node', args: { id: 'a', index: 0 } },
      { command: 'select', args: { ids: [] } },
      { command: 'undo', args: {} },
      { command: 'new_document', args: { discard: true } },
      { command: 'open_document', args: { path: '/repo/designs/home.fudehand' } },
      { command: 'save_document', args: {} },
      { command: 'save_document', args: { path: '/tmp/a.fudehand' } },
      { command: 'zoom', args: { scale: 0.5 } },
      { command: 'list_fonts', args: {} },
      { command: 'import_font', args: { path: '/repo/fonts/Brand.otf' } },
    ])
  })

  it('expands ~ in file and image paths to the home directory', async () => {
    const home = await mkdtemp(join(tmpdir(), 'uia-home-'))
    cleanup.push(() => rm(home, { recursive: true, force: true }))
    await writeFile(join(home, 'dot.png'), Buffer.from(PNG, 'base64'))
    vi.stubEnv('HOME', home)
    cleanup.push(async () => vi.unstubAllEnvs())
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    await callTool('design_save_document', { path: '~/Desktop/a.fudehand' }, ctx)
    await callTool('design_open_document', { path: '~' }, ctx)
    await callTool('design_create_node', { node: { type: 'image', image: { path: '~/dot.png' } } }, ctx)
    await callTool('design_open_document', { path: '~other/a.fudehand' }, ctx)
    expect(fake.received.map(({ args }) => args)).toEqual([
      { path: join(home, 'Desktop/a.fudehand') },
      { path: home },
      { node: { type: 'image', image: { data: PNG } } },
      { path: '/repo/~other/a.fudehand' },
    ])
  })

  it('reads image.path into base64, including child layers and updates', async () => {
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
    expect(text(missing)).toBe('Could not read image: nope.png')
    expect(fake.received).toHaveLength(2)
  })

  it('reads an SVG image.path byte for byte', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'uia-image-'))
    cleanup.push(() => rm(dir, { recursive: true, force: true }))
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>\n'
    await writeFile(join(dir, 'icon.svg'), svg)
    const fake = await app(echo)
    await callTool('design_create_node', { node: { type: 'image', image: { path: 'icon.svg' } } }, { root: dir, socketPath: fake.socketPath })
    expect(fake.received[0].args.node).toEqual({ type: 'image', image: { data: Buffer.from(svg).toString('base64') } })
  })

  it('passes through error messages returned by the App', async () => {
    const fake = await app(() => ({ ok: false, error: 'Layer e: ellipse does not support layout' }))
    const result = await callTool('design_update_node', { id: 'e', changes: { layout: {} } }, { root: '/repo', socketPath: fake.socketPath })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('Layer e: ellipse does not support layout')
  })

  it('returns "Fudehand is not running" when the App is not running', async () => {
    const socketPath = join(tmpdir(), `uia-missing-${randomUUID().slice(0, 8)}.sock`)
    const result = await callTool('design_get_state', {}, { root: '/repo', socketPath })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('Fudehand is not running')
  })

  it('has English tool and parameter descriptions, with no Chinese', () => {
    for (const tool of tools) {
      // The Chinese range is deliberate: it asserts the descriptions contain no Chinese.
      expect(JSON.stringify({ description: tool.description, inputSchema: tool.inputSchema }), tool.name).not.toMatch(/[一-鿿]/)
    }
  })

  it('sends a 10 MB image to the App in full', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'uia-image-'))
    cleanup.push(() => rm(dir, { recursive: true, force: true }))
    const image = Buffer.alloc(10 << 20, 7)
    await writeFile(join(dir, 'big.png'), image)
    const fake = await app(echo)
    const created = await callTool('design_create_node', { node: { type: 'image', image: { path: 'big.png' } } }, { root: dir, socketPath: fake.socketPath })
    expect(created.isError).toBeUndefined()
    const sent = (fake.received[0].args.node as { image: { data: string } }).image.data
    expect(Buffer.from(sent, 'base64').equals(image)).toBe(true)
  })

  it('design_snapshot returns the snapshot as MCP image content', async () => {
    const fake = await app(() => ({ ok: true, result: { id: 'home', mimeType: 'image/png', data: PNG, width: 390, height: 844 } }))
    const result = await callTool('design_snapshot', { id: 'home' }, { root: '/repo', socketPath: fake.socketPath })
    expect(fake.received[0]).toMatchObject({ command: 'node_snapshot', args: { id: 'home' } })
    expect(result.content).toEqual([
      { type: 'image', data: PNG, mimeType: 'image/png' },
      { type: 'text', text: 'Snapshot of layer home (390×844)' },
    ])
  })

  it('parses a response in full when it spans chunks and is split inside a Chinese character', async () => {
    // Chinese kept deliberately: the chunk boundary must fall inside a multi-byte character.
    const error = 'Layer not found: 手机'
    const fake = await app(() => ({ ok: false, error }), { splitInside: '手' })
    const result = await callTool('design_get_node', { id: '手机' }, { root: '/repo', socketPath: fake.socketPath })
    expect(text(result)).toBe(error)
  })

  it('reads a snapshot response of several MB', async () => {
    const data = 'A'.repeat(6 << 20)
    const fake = await app(() => ({ ok: true, result: { id: 'web', mimeType: 'image/png', data, width: 1440, height: 900 } }))
    const result = await callTool('design_snapshot', { id: 'web' }, { root: '/repo', socketPath: fake.socketPath })
    expect(result.content[0].data.length).toBe(data.length)
  })
})
