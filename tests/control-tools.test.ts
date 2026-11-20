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
      'canvas_focus_node', 'canvas_fit_all', 'canvas_zoom', 'canvas_set_view', 'prototype_play', 'prototype_get_playback', 'prototype_close', 'design_list_fonts', 'design_import_font', 'design_search_icons', 'design_list_colors', 'design_replace_color', 'design_save_version_snapshot', 'design_list_version_snapshots',
      'design_list_annotations', 'design_add_annotation', 'design_update_annotation', 'design_delete_annotation', 'design_snapshot', 'design_export_html',
      'app_show_launch_window', 'app_list_recents', 'app_open_recent', 'app_remove_recent', 'app_clear_recents',
      'app_list_templates', 'app_new_document_from_template',
      'chat_list_conversations', 'chat_get_conversation', 'chat_open_conversation', 'chat_new_conversation', 'chat_close_conversation',
      'chat_delete_conversation', 'chat_clear_conversation', 'chat_send_message', 'chat_set_mode', 'chat_run_plan', 'chat_stop_reply', 'chat_regenerate_reply',
      'chat_edit_last_message', 'chat_answer_question', 'chat_compact_conversation',
      'settings_get_interface', 'settings_update_interface', 'settings_get_models', 'settings_update_model_provider',
      'settings_list_models', 'settings_set_api_key', 'settings_delete_api_key', 'settings_get_connectors', 'settings_set_connector',
      'style_list', 'style_read',
    ])
    for (const tool of tools as { inputSchema: { type: string } }[]) expect(tool.inputSchema.type).toBe('object')
  })

  it('forwards the prototype window tools and their arguments unchanged', async () => {
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    await callTool('prototype_play', {}, ctx)
    await callTool('prototype_play', { frame: 'home' }, ctx)
    await callTool('prototype_get_playback', {}, ctx)
    await callTool('prototype_close', {}, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'play', args: {} },
      { command: 'play', args: { frame: 'home' } },
      { command: 'get_playback', args: {} },
      { command: 'close', args: {} },
    ])
    await fake.close()
  })

  it('describes interactions and forwards them to the App unchanged', async () => {
    const byName = (name: string) => (tools as { name: string, description: string }[]).find(tool => tool.name === name)!
    for (const field of ['interaction', 'navigate', 'back', 'destination', 'push-left', 'sheet', 'ease-in-out'])
      expect(byName('design_create_node').description).toContain(field)
    expect(byName('design_update_node').description).toContain('interaction, animation, states, and text.sequence are replaced whole')
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
    expect(byName('design_update_node').description).toContain('interaction, animation, states, and text.sequence are replaced whole')
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

  it('describes frame layout guides and forwards them unchanged', async () => {
    const byName = (name: string) => (tools as { name: string, description: string }[]).find(tool => tool.name === name)!
    for (const field of ['layoutGuides', 'grid', 'columns', 'rows', 'gutter', 'margin', 'stretch', 'visible'])
      expect(byName('design_create_node').description).toContain(field)
    expect(byName('design_update_node').description).toContain('layoutGuides array is replaced whole')
    const fake = await app(echo)
    const changes = { layoutGuides: [{ type: 'columns', count: 12, gutter: 24, margin: 32 }, { type: 'grid', size: 8, visible: false }] }
    await callTool('design_update_node', { id: 'a', changes }, { root: '/repo', socketPath: fake.socketPath })
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([{ command: 'update_node', args: { id: 'a', changes } }])
    await fake.close()
  })

  it('describes animations and text sequences and forwards them unchanged', async () => {
    const byName = (name: string) => (tools as { name: string, description: string }[]).find(tool => tool.name === name)!
    for (const field of ['animation', 'fade-in', 'slide-in', 'scale-in', 'spin', 'pulse', 'shimmer', 'delay', 'repeat', '"infinite"', 'text.sequence', 'interval', 'loop'])
      expect(byName('design_create_node').description).toContain(field)
    expect(byName('design_update_node').description).toContain('interaction, animation, states, and text.sequence are replaced whole')
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

  it('lists and replaces selection colors through the App', async () => {
    const byName = (name: string) => (tools as { name: string, description: string, inputSchema: any }[]).find(tool => tool.name === name)!
    expect(byName('design_list_colors').inputSchema.required).toEqual([])
    expect(byName('design_replace_color').inputSchema.required).toEqual(['from', 'to'])
    for (const field of ['fill', 'stroke', 'text color', 'icon color', 'child layers'])
      expect(byName('design_list_colors').description).toContain(field)
    expect(byName('design_replace_color').description).toContain('single undo step')
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    await callTool('design_list_colors', {}, ctx)
    await callTool('design_list_colors', { ids: ['f'] }, ctx)
    await callTool('design_replace_color', { from: '#FF0000', to: '#00FF00' }, ctx)
    await callTool('design_replace_color', { from: '#FF0000', to: '#00FF00', ids: ['a', 'b'] }, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'list_colors', args: {} },
      { command: 'list_colors', args: { ids: ['f'] } },
      { command: 'replace_color', args: { from: '#FF0000', to: '#00FF00' } },
      { command: 'replace_color', args: { from: '#FF0000', to: '#00FF00', ids: ['a', 'b'] } },
    ])
  })

  it('reads and writes annotations through the App', async () => {
    const byName = (name: string) => (tools as { name: string, description: string, inputSchema: any }[]).find(tool => tool.name === name)!
    expect(byName('design_list_annotations').inputSchema.required).toEqual([])
    expect(byName('design_add_annotation').inputSchema.required).toEqual(['text'])
    expect(byName('design_update_annotation').inputSchema.required).toEqual(['id', 'text'])
    expect(byName('design_delete_annotation').inputSchema.required).toEqual(['id'])
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    await callTool('design_list_annotations', {}, ctx)
    await callTool('design_list_annotations', { node: 'card' }, ctx)
    await callTool('design_add_annotation', { node: 'card', x: 4, y: 0, text: 'Why two buttons?' }, ctx)
    await callTool('design_add_annotation', { replyTo: 'n1', text: 'One is secondary', extra: 1 }, ctx)
    await callTool('design_update_annotation', { id: 'n1', text: '' }, ctx)
    await callTool('design_delete_annotation', { id: 'n1' }, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'list_annotations', args: {} },
      { command: 'list_annotations', args: { node: 'card' } },
      { command: 'add_annotation', args: { node: 'card', x: 4, y: 0, text: 'Why two buttons?' } },
      { command: 'add_annotation', args: { replyTo: 'n1', text: 'One is secondary' } },
      { command: 'update_annotation', args: { id: 'n1', text: '' } },
      { command: 'delete_annotation', args: { id: 'n1' } },
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
    await callTool('canvas_focus_node', { id: 'a' }, ctx)
    await callTool('canvas_focus_node', { ids: ['a', 'b'] }, ctx)
    await callTool('canvas_set_view', { tool: 'hand', inspector: false, inspectorTab: 'chat', expand: ['a'], collapse: ['b'] }, ctx)
    await callTool('design_list_fonts', {}, ctx)
    await callTool('design_import_font', { path: 'fonts/Brand.otf' }, ctx)
    await callTool('design_export_html', { id: 'f', directory: 'out/home' }, ctx)
    await callTool('design_export_html', { id: 'f', directory: '/work/site/design' }, ctx)
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
      { command: 'focus_node', args: { id: 'a' } },
      { command: 'focus_node', args: { ids: ['a', 'b'] } },
      { command: 'set_view', args: { tool: 'hand', inspector: false, inspectorTab: 'chat', expand: ['a'], collapse: ['b'] } },
      { command: 'list_fonts', args: {} },
      { command: 'import_font', args: { path: '/repo/fonts/Brand.otf' } },
      { command: 'export_html', args: { id: 'f', directory: '/repo/out/home' } },
      { command: 'export_html', args: { id: 'f', directory: '/work/site/design' } },
    ])
  })

  it('forwards the launch window, recent file, and template tools to the App', async () => {
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    await callTool('app_show_launch_window', {}, ctx)
    await callTool('app_list_recents', {}, ctx)
    await callTool('app_open_recent', { path: '/Users/a/Home.fudehand' }, ctx)
    await callTool('app_open_recent', { path: '/Users/a/Home.fudehand', discard: true }, ctx)
    await callTool('app_remove_recent', { path: '/Users/a/Old.fudehand' }, ctx)
    await callTool('app_clear_recents', {}, ctx)
    await callTool('app_list_templates', {}, ctx)
    await callTool('app_new_document_from_template', { name: 'Mobile', discard: true }, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'show_launch_window', args: {} },
      { command: 'list_recents', args: {} },
      { command: 'open_recent', args: { path: '/Users/a/Home.fudehand' } },
      { command: 'open_recent', args: { path: '/Users/a/Home.fudehand', discard: true } },
      { command: 'remove_recent', args: { path: '/Users/a/Old.fudehand' } },
      { command: 'clear_recents', args: {} },
      { command: 'list_templates', args: {} },
      { command: 'new_document_from_template', args: { name: 'Mobile', discard: true } },
    ])
    const byName = (name: string) => (tools as { name: string, inputSchema: { required: string[] } }[]).find(tool => tool.name === name)!
    expect(byName('app_open_recent').inputSchema.required).toEqual(['path'])
    expect(byName('app_remove_recent').inputSchema.required).toEqual(['path'])
    expect(byName('app_new_document_from_template').inputSchema.required).toEqual(['name'])
  })

  it('forwards the chat tools and their arguments to the App unchanged', async () => {
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    const id = '8E0A1C2B-3D4E-4F50-8172-93A4B5C6D7E8'
    const calls: [string, Record<string, unknown>, string, Record<string, unknown>][] = [
      ['chat_list_conversations', {}, 'list_conversations', {}],
      ['chat_get_conversation', { id }, 'get_conversation', { id }],
      ['chat_open_conversation', { id }, 'open_conversation', { id }],
      ['chat_new_conversation', {}, 'new_conversation', {}],
      ['chat_close_conversation', { id }, 'close_conversation', { id }],
      ['chat_delete_conversation', { id }, 'delete_conversation', { id }],
      ['chat_clear_conversation', {}, 'clear_conversation', {}],
      ['chat_send_message', { id, text: 'Make it blue', context: ['hero'], mode: 'goal' }, 'send_message', { id, text: 'Make it blue', context: ['hero'], mode: 'goal' }],
      ['chat_set_mode', { mode: 'none' }, 'set_mode', { mode: 'none' }],
      ['chat_run_plan', { context: ['hero'] }, 'run_plan', { context: ['hero'] }],
      ['chat_stop_reply', { id }, 'stop_reply', { id }],
      ['chat_regenerate_reply', {}, 'regenerate_reply', {}],
      ['chat_edit_last_message', { text: 'Make it red', context: [] }, 'edit_last_message', { text: 'Make it red', context: [] }],
      ['chat_answer_question', { text: 'Dark' }, 'answer_question', { text: 'Dark' }],
      ['chat_answer_question', { skip: true }, 'answer_question', { skip: true }],
      ['chat_compact_conversation', { id }, 'compact_conversation', { id }],
    ]
    for (const [name, args] of calls) expect((await callTool(name, args, ctx)).isError, name).toBeFalsy()
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual(calls.map(([, , command, args]) => ({ command, args })))
    // Only the in-App Agent names its conversation as the caller.
    expect(fake.received.every(request => !('caller' in request))).toBe(true)
  })

  it('names the calling conversation so the App can refuse to let it act on itself', async () => {
    const id = '8E0A1C2B-3D4E-4F50-8172-93A4B5C6D7E8'
    const fake = await app(request => (request as { caller?: string }).caller === id && request.command === 'stop_reply'
      ? { ok: false, error: 'A conversation cannot stop itself; this command was sent by the Agent of that conversation' } : echo(request))
    const ctx = { root: '/repo', socketPath: fake.socketPath, conversation: id }
    const refused = await callTool('chat_stop_reply', {}, ctx)
    expect(refused.isError).toBe(true)
    expect(text(refused)).toContain('cannot stop itself')
    await callTool('design_get_state', {}, ctx)
    expect(fake.received.map(request => (request as { caller?: string }).caller)).toEqual([id, id])
    for (const name of ['chat_close_conversation', 'chat_delete_conversation', 'chat_send_message', 'chat_stop_reply', 'chat_set_mode'])
      expect((tools as { name: string, description: string }[]).find(tool => tool.name === name)!.description).toContain('Refused for the conversation whose Agent is calling')
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

  it('forwards version snapshot tools to the App unchanged', async () => {
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    await callTool('design_save_version_snapshot', { frame: 'home', note: 'Before the redesign' }, ctx)
    await callTool('design_save_version_snapshot', { frame: 'home' }, ctx)
    await callTool('design_list_version_snapshots', { frame: 'home' }, ctx)
    await callTool('design_list_version_snapshots', {}, ctx)
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual([
      { command: 'save_version_snapshot', args: { frame: 'home', note: 'Before the redesign' } },
      { command: 'save_version_snapshot', args: { frame: 'home' } },
      { command: 'list_version_snapshots', args: { frame: 'home' } },
      { command: 'list_version_snapshots', args: {} },
    ])
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

describe('settings tools', () => {
  it('forwards every settings command and its arguments to the App unchanged', async () => {
    const fake = await app(echo)
    const ctx = { root: '/repo', socketPath: fake.socketPath }
    const calls: [string, Record<string, unknown>, string][] = [
      ['settings_get_interface', {}, 'get_interface'],
      ['settings_update_interface', { language: 'zh-Hans', appearance: 'dark' }, 'update_interface'],
      ['settings_get_models', {}, 'get_models'],
      ['settings_update_model_provider', { provider: 'openai', model: '', baseUrl: 'https://example.test/v1', use: true }, 'update_model_provider'],
      ['settings_list_models', { provider: 'deepseek', baseUrl: '' }, 'list_models'],
      ['settings_set_api_key', { provider: 'anthropic', key: 'sk-ant-0000-1111-2222' }, 'set_api_key'],
      ['settings_delete_api_key', { provider: 'anthropic' }, 'delete_api_key'],
      ['settings_get_connectors', {}, 'get_connectors'],
      ['settings_set_connector', { connector: 'codex', connected: false }, 'set_connector'],
    ]
    for (const [name, args] of calls) {
      const result = await callTool(name, args, ctx)
      expect(result.isError).toBeUndefined()
    }
    expect(fake.received.map(({ command, args }) => ({ command, args }))).toEqual(calls.map(([, args, command]) => ({ command, args })))
  })

  it('marks the API key as a secret argument, and only that', async () => {
    const { secretArguments } = await import('../scripts/fudehand-tools.mjs')
    expect(secretArguments).toEqual({ settings_set_api_key: ['key'] })
    const tool = (tools as { name: string, inputSchema: { required: string[] } }[]).find(item => item.name === 'settings_set_api_key')!
    expect(tool.inputSchema.required).toEqual(['provider', 'key'])
  })
})
