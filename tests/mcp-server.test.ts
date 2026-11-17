import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'

const server = fileURLToPath(new URL('../scripts/mcp-server.mjs', import.meta.url))
const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

function sampleCatalog() {
  return {
    version: 1,
    projects: [{
      id: 'demo', title: '演示作品', subtitle: '', description: '', author: '原创作者', sourceUrl: null, framework: 'HTML', tags: [], enabled: true, layoutVersion: 1,
      preview: { cwd: 'examples/demo', command: ['pnpm', 'dev'], port: 31002, baseUrl: 'http://127.0.0.1:31002/demo/' },
      frames: [
        { id: 'home', title: '首页', platform: 'web', path: 'home', width: 1440, height: 900, x: 0, y: 0 },
        { id: 'phone', title: '手机', platform: 'mobile', path: '/demo/m?x=1', width: 390, height: 844, x: 1600, y: 0 },
      ],
    }],
  }
}

async function workspace(catalog: unknown = sampleCatalog()) {
  const root = await mkdtemp(join(tmpdir(), 'ui-atlas-mcp-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  await mkdir(join(root, 'examples/demo'), { recursive: true })
  await writeFile(join(root, 'catalog.json'), JSON.stringify(catalog, null, 2) + '\n')
  return root
}

async function connect(root: string) {
  const client = new Client({ name: 'ui-atlas-test', version: '0.0.0' })
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [server, '--root', root], stderr: 'ignore' }))
  cleanup.push(() => client.close())
  return client
}

function text(result: { content: unknown }) {
  return (result.content as { type: string, text: string }[]).map(item => item.text).join('\n')
}

describe('MCP server：只读作品工具', () => {
  it('列出三个只读工具', async () => {
    const client = await connect(await workspace())
    const { tools } = await client.listTools()
    expect(tools.map(tool => tool.name)).toEqual(expect.arrayContaining(['list_projects', 'get_project', 'get_preview_urls']))
  })

  it('list_projects 返回作品摘要', async () => {
    const client = await connect(await workspace())
    const result = await client.callTool({ name: 'list_projects', arguments: {} })
    expect(result.isError).toBeFalsy()
    expect(JSON.parse(text(result))).toEqual([{ id: 'demo', title: '演示作品', framework: 'HTML', enabled: true, frameCount: 2, baseUrl: 'http://127.0.0.1:31002/demo/' }])
  })

  it('get_project 返回完整配置', async () => {
    const client = await connect(await workspace())
    const result = await client.callTool({ name: 'get_project', arguments: { project: 'demo' } })
    expect(JSON.parse(text(result))).toEqual(sampleCatalog().projects[0])
  })

  it('get_preview_urls 按 baseUrl 解析画框地址', async () => {
    const client = await connect(await workspace())
    const result = await client.callTool({ name: 'get_preview_urls', arguments: { project: 'demo' } })
    expect(JSON.parse(text(result))).toEqual([
      { frame: 'home', title: '首页', url: 'http://127.0.0.1:31002/demo/home', width: 1440, height: 900, platform: 'web' },
      { frame: 'phone', title: '手机', url: 'http://127.0.0.1:31002/demo/m?x=1', width: 390, height: 844, platform: 'mobile' },
    ])
  })

  it('未知作品返回中文错误', async () => {
    const client = await connect(await workspace())
    const result = await client.callTool({ name: 'get_project', arguments: { project: 'missing' } })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('找不到作品：missing')
  })

  it('缺少作品参数时返回中文错误', async () => {
    const client = await connect(await workspace())
    const result = await client.callTool({ name: 'get_preview_urls', arguments: {} })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('缺少参数：project')
  })

  it('非法 catalog 返回 launcher 的校验错误', async () => {
    const catalog = sampleCatalog()
    catalog.projects[0].frames[0].width = 0
    const client = await connect(await workspace(catalog))
    const result = await client.callTool({ name: 'list_projects', arguments: {} })
    expect(result.isError).toBe(true)
    expect(text(result)).toBe('配置错误：demo/home 的宽高必须是有限正数')
  })
})
