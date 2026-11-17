import { afterEach, describe, expect, it } from 'vitest'
import { readFile, readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { callTool } from '../scripts/atlas-tools.mjs'
import { atlasWorkspace, sampleCatalog } from './helpers/atlas-workspace'

const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

async function workspace(catalog: unknown = sampleCatalog()) {
  const { root, dispose } = await atlasWorkspace(catalog)
  cleanup.push(dispose)
  return root
}

const read = (root: string) => readFile(join(root, 'catalog.json'), 'utf8')
const text = (result: { content: { text: string }[] }) => result.content.map(item => item.text).join('\n')
const tablet = { id: 'tablet', title: '平板', platform: 'mobile', path: '/demo/tablet', width: 820, height: 1180 }

async function expectRejected(root: string, name: string, args: object, message: string) {
  const before = await read(root)
  const result = await callTool(name, args, { root })
  expect(result.isError).toBe(true)
  expect(text(result)).toContain(message)
  expect(await read(root)).toBe(before)
  expect((await readdir(root)).filter(file => file.endsWith('.tmp'))).toEqual([])
}

describe('作品数据层写入工具', () => {
  it('add_frame 写入后保持 2 空格缩进与末尾换行，缺省坐标放在最右侧', async () => {
    const root = await workspace()
    const result = await callTool('add_frame', { project: 'demo', frame: tablet }, { root })
    expect(result.isError).toBeFalsy()
    expect(text(result)).toContain('已添加画框 demo/tablet')
    const raw = await read(root)
    const expected = sampleCatalog()
    expected.projects[0].frames.push({ ...tablet, x: 2070, y: 0 })
    expect(raw).toBe(JSON.stringify(expected, null, 2) + '\n')
  })

  it('连续两次写入都保留', async () => {
    const root = await workspace()
    await callTool('add_frame', { project: 'demo', frame: tablet }, { root })
    await callTool('add_frame', { project: 'demo', frame: { ...tablet, id: 'tablet-2', x: 0, y: 1200 } }, { root })
    const frames = JSON.parse(await read(root)).projects[0].frames.map((frame: { id: string }) => frame.id)
    expect(frames).toEqual(['home', 'phone', 'tablet', 'tablet-2'])
  })

  it('并发写入依次执行，全部保留', async () => {
    const root = await workspace()
    const results = await Promise.all(['a', 'b', 'c', 'd'].map(id => callTool('add_frame', { project: 'demo', frame: { ...tablet, id } }, { root })))
    expect(results.map(result => result.isError)).toEqual([undefined, undefined, undefined, undefined])
    const frames = JSON.parse(await read(root)).projects[0].frames.map((frame: { id: string }) => frame.id)
    expect(frames).toEqual(['home', 'phone', 'a', 'b', 'c', 'd'])
  })

  it('update_frame 只改动给出的字段', async () => {
    const root = await workspace()
    const result = await callTool('update_frame', { project: 'demo', frame: 'phone', changes: { title: '手机竖屏', width: 375 } }, { root })
    expect(result.isError).toBeFalsy()
    const phone = JSON.parse(await read(root)).projects[0].frames[1]
    expect(phone).toEqual({ ...sampleCatalog().projects[0].frames[1], title: '手机竖屏', width: 375 })
  })

  it('remove_frame 删除画框', async () => {
    const root = await workspace()
    expect((await callTool('remove_frame', { project: 'demo', frame: 'home' }, { root })).isError).toBeFalsy()
    expect(JSON.parse(await read(root)).projects[0].frames.map((frame: { id: string }) => frame.id)).toEqual(['phone'])
  })

  it('set_project_enabled 写入并提示重启预览', async () => {
    const root = await workspace()
    const result = await callTool('set_project_enabled', { project: 'demo', enabled: false }, { root })
    expect(text(result)).toContain('需要重启预览')
    expect(JSON.parse(await read(root)).projects[0].enabled).toBe(false)
  })

  it('校验失败时返回 launcher 的中文错误且不改文件', async () => {
    const root = await workspace()
    await expectRejected(root, 'add_frame', { project: 'demo', frame: { ...tablet, id: 'home' } }, '画框 id 必须非空且唯一')
    await expectRejected(root, 'add_frame', { project: 'demo', frame: { ...tablet, path: 'http://127.0.0.1:4401/' } }, '必须指向该作品的本地预览服务')
    await expectRejected(root, 'update_frame', { project: 'demo', frame: 'home', changes: { width: -1 } }, '宽高必须是有限正数')
    await callTool('remove_frame', { project: 'demo', frame: 'home' }, { root })
    await expectRejected(root, 'remove_frame', { project: 'demo', frame: 'phone' }, '配置错误：demo 至少需要一个画框')
  })

  it('catalog 本身非法时拒绝任何写入', async () => {
    const catalog = sampleCatalog()
    catalog.projects.push({ ...structuredClone(catalog.projects[0]), id: 'other' })
    const root = await workspace(catalog)
    await expectRejected(root, 'set_project_enabled', { project: 'other', enabled: false }, '端口 31002 重复')
  })

  it('拒绝未知画框、未知字段和错误参数', async () => {
    const root = await workspace()
    await expectRejected(root, 'update_frame', { project: 'demo', frame: 'nope', changes: { title: 'x' } }, '找不到画框：demo/nope')
    await expectRejected(root, 'update_frame', { project: 'demo', frame: 'home', changes: { color: 'red' } }, '不支持修改字段：color')
    await expectRejected(root, 'set_project_enabled', { project: 'demo', enabled: 'no' }, '参数类型错误：enabled')
    await expectRejected(root, 'add_frame', { project: 'demo' }, '缺少参数：frame')
    await expectRejected(root, 'update_frame', { project: 'demo', frame: 'home', changes: {} }, '缺少参数：changes')
    await expectRejected(root, 'update_frame', { project: 'demo', frame: 'home', changes: [] }, '缺少参数：changes')
  })
})
