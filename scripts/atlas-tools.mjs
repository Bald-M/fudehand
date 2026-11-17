import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { servicesFromCatalog } from './launcher.mjs'

/** 读取并用与 launcher 相同的规则校验 catalog.json。 */
export async function loadCatalog(root) {
  let catalog
  try { catalog = JSON.parse(await readFile(resolve(root, 'catalog.json'), 'utf8')) }
  catch (error) { throw new Error(`无法读取 catalog.json：${error instanceof Error ? error.message : String(error)}`) }
  await servicesFromCatalog(catalog, root)
  return catalog
}

function findProject(catalog, id) {
  if (typeof id !== 'string') throw new Error('缺少参数：project')
  const project = catalog.projects.find(item => item.id === id)
  if (!project) throw new Error(`找不到作品：${id}`)
  return project
}

const json = value => ({ content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] })
const projectArg = { project: { type: 'string', description: '作品 id' } }

/** MCP server 与 App 内 Agent harness 共用的唯一工具实现。 */
export const tools = [
  {
    name: 'list_projects',
    description: '列出界面图鉴中的全部作品摘要（id、标题、框架、是否启用、画框数、预览 baseUrl）。',
    inputSchema: { type: 'object', properties: {} },
    async run(_args, { root }) {
      const catalog = await loadCatalog(root)
      return json(catalog.projects.map(project => ({
        id: project.id, title: project.title, framework: project.framework, enabled: project.enabled,
        frameCount: project.frames.length, baseUrl: project.preview.baseUrl,
      })))
    },
  },
  {
    name: 'get_project',
    description: '读取单个作品在 catalog.json 中的完整配置，包括预览启动参数和全部画框。',
    inputSchema: { type: 'object', properties: projectArg, required: ['project'] },
    async run({ project }, { root }) {
      return json(findProject(await loadCatalog(root), project))
    },
  },
  {
    name: 'get_preview_urls',
    description: '返回作品每个画框的预览 URL、宽高与平台，可用浏览器工具直接访问。',
    inputSchema: { type: 'object', properties: projectArg, required: ['project'] },
    async run({ project }, { root }) {
      const found = findProject(await loadCatalog(root), project)
      return json(found.frames.map(frame => ({
        frame: frame.id, title: frame.title, url: new URL(frame.path, found.preview.baseUrl).href,
        width: frame.width, height: frame.height, platform: frame.platform,
      })))
    },
  },
]

/** 调用工具；任何错误都转为带中文消息的错误结果，而不是抛出。 */
export async function callTool(name, args, ctx) {
  const tool = tools.find(item => item.name === name)
  try {
    if (!tool) throw new Error(`未知工具：${name}`)
    return await tool.run(args ?? {}, ctx)
  } catch (error) {
    return { isError: true, content: [{ type: 'text', text: error instanceof Error ? error.message : String(error) }] }
  }
}
