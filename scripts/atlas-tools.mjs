import { randomUUID } from 'node:crypto'
import { readFile, rename, rm, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { servicesFromCatalog } from './launcher.mjs'
import { sendControl } from './control-client.mjs'

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

function findFrame(project, id) {
  if (typeof id !== 'string') throw new Error('缺少参数：frame')
  const frame = project.frames.find(item => item.id === id)
  if (!frame) throw new Error(`找不到画框：${project.id}/${id}`)
  return frame
}

// Agent 常并发调用工具；本进程内的写入排队执行，避免读到旧内容而覆盖彼此的修改。
// 不防护其他进程同时写入 catalog.json。
let writes = Promise.resolve()

/** 读取 → 修改内存副本 → 与 launcher 相同的校验 → 临时文件 + rename 原子替换。校验失败时不改文件。 */
function updateCatalog(root, change) {
  const result = writes.then(() => writeCatalog(root, change))
  writes = result.catch(() => {})
  return result
}

async function writeCatalog(root, change) {
  const next = await loadCatalog(root)
  const message = change(next)
  await servicesFromCatalog(next, root)
  const target = resolve(root, 'catalog.json')
  const temporary = `${target}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, JSON.stringify(next, null, 2) + '\n')
    await rename(temporary, target)
  } catch (error) {
    await rm(temporary, { force: true })
    throw error
  }
  // App 只在打开项目时读取 catalog.json。
  return { content: [{ type: 'text', text: `${message}。界面图鉴正在运行时，需要重启预览后生效。` }] }
}

const frameFields = ['title', 'platform', 'path', 'width', 'height', 'x', 'y']
const json = value => ({ content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] })
const projectArg = { project: { type: 'string', description: '作品 id' } }
const frameProperties = {
  id: { type: 'string' }, title: { type: 'string' }, platform: { type: 'string', enum: ['mobile', 'web', 'desktop'] },
  path: { type: 'string', description: '相对作品 baseUrl 的路径，必须指向该作品的预览服务' },
  width: { type: 'number' }, height: { type: 'number' }, x: { type: 'number' }, y: { type: 'number' },
}

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
  {
    name: 'add_frame',
    description: '给作品新增一个画框。未给 x、y 时放在现有画框右侧。写入前按 launcher 规则校验整个 catalog。',
    inputSchema: {
      type: 'object', required: ['project', 'frame'],
      properties: { ...projectArg, frame: { type: 'object', properties: frameProperties, required: ['id', 'title', 'platform', 'path', 'width', 'height'] } },
    },
    run({ project, frame }, { root }) {
      return updateCatalog(root, catalog => {
        const found = findProject(catalog, project)
        if (!frame || typeof frame !== 'object') throw new Error('缺少参数：frame')
        const right = Math.max(...found.frames.map(item => item.x + item.width)) + 80
        found.frames.push({ id: frame.id, title: frame.title, platform: frame.platform, path: frame.path, width: frame.width, height: frame.height, x: frame.x ?? right, y: frame.y ?? 0 })
        return `已添加画框 ${found.id}/${frame.id}`
      })
    },
  },
  {
    name: 'update_frame',
    description: `修改画框的部分字段（${frameFields.join('、')}）。写入前按 launcher 规则校验整个 catalog。`,
    inputSchema: {
      type: 'object', required: ['project', 'frame', 'changes'],
      properties: {
        ...projectArg, frame: { type: 'string', description: '画框 id' },
        changes: { type: 'object', properties: Object.fromEntries(frameFields.map(key => [key, frameProperties[key]])) },
      },
    },
    run({ project, frame, changes }, { root }) {
      return updateCatalog(root, catalog => {
        const found = findFrame(findProject(catalog, project), frame)
        if (!changes || typeof changes !== 'object' || Array.isArray(changes) || !Object.keys(changes).length) throw new Error('缺少参数：changes')
        const unknown = Object.keys(changes).filter(key => !frameFields.includes(key))
        if (unknown.length) throw new Error(`不支持修改字段：${unknown.join('、')}`)
        Object.assign(found, changes)
        return `已更新画框 ${project}/${frame}`
      })
    },
  },
  {
    name: 'remove_frame',
    description: '删除作品的一个画框。作品至少要保留一个画框。',
    inputSchema: { type: 'object', required: ['project', 'frame'], properties: { ...projectArg, frame: { type: 'string', description: '画框 id' } } },
    run({ project, frame }, { root }) {
      return updateCatalog(root, catalog => {
        const found = findProject(catalog, project)
        const removed = findFrame(found, frame)
        found.frames = found.frames.filter(item => item !== removed)
        return `已删除画框 ${project}/${frame}`
      })
    },
  },
  {
    name: 'set_project_enabled',
    description: '启用或停用作品。停用的作品不启动预览服务，也不能在画布中选择。',
    inputSchema: { type: 'object', required: ['project', 'enabled'], properties: { ...projectArg, enabled: { type: 'boolean' } } },
    run({ project, enabled }, { root }) {
      return updateCatalog(root, catalog => {
        if (typeof enabled !== 'boolean') throw new Error('参数类型错误：enabled')
        findProject(catalog, project).enabled = enabled
        return `已${enabled ? '启用' : '停用'}作品 ${project}`
      })
    },
  },
]

/** 画布控制层：经本地控制通道转发给正在运行的 App。 */
function canvasTool(name, command, description, properties = {}, required = Object.keys(properties)) {
  return {
    name, description: `${description}需要界面图鉴正在运行。`,
    inputSchema: { type: 'object', properties, required },
    async run(args, { socketPath }) {
      const forwarded = Object.fromEntries(Object.keys(properties).map(key => [key, args[key]]))
      return json(await sendControl(command, forwarded, { socketPath }))
    },
  }
}

const frameArg = { frame: { type: 'string', description: '当前作品的画框 id' } }

tools.push(
  canvasTool('canvas_get_state', 'get_state', '读取画布状态：当前作品、选择、视口、画框位置与预览阶段。'),
  canvasTool('canvas_select_project', 'select_project', '在画布中切换到指定作品（必须已启用）。', projectArg),
  canvasTool('canvas_focus_frame', 'focus_frame', '把视口移动并缩放到当前作品的指定画框。', { frame: { type: 'string', description: '画框 id' } }),
  canvasTool('canvas_fit_all', 'fit_all', '缩放视口以显示当前作品的全部画框。'),
  canvasTool('canvas_zoom', 'zoom', '以画布中心为基准缩放到指定比例（1 为实际大小，范围 0.05～4）。', { scale: { type: 'number' } }),
  canvasTool('canvas_reset', 'reset', '恢复当前作品的默认布局，撤销保存的画框位置和视角。'),
  canvasTool('canvas_restart_preview', 'restart_preview', '重新读取 catalog.json 并重启全部预览服务；修改 catalog 后用它让 App 生效。'),
  {
    name: 'frame_snapshot',
    description: '截取当前作品中某个画框在 App 内实际渲染的网页，返回 PNG。需要界面图鉴正在运行且画框已加载。',
    inputSchema: { type: 'object', properties: { frame: { type: 'string', description: '画框 id' } }, required: ['frame'] },
    async run({ frame }, { socketPath }) {
      const shot = await sendControl('frame_snapshot', { frame }, { socketPath })
      return { content: [
        { type: 'image', data: shot.data, mimeType: shot.mimeType },
        { type: 'text', text: `画框 ${shot.frame} 的截图（${shot.width}×${shot.height}）` },
      ] }
    },
  },
)

// 画框页面层：只作用于画框中已加载的本机预览页面，不提供导航到其他站点的能力。
tools.push(
  canvasTool('frame_console', 'frame_console',
    '读取画框网页最近的控制台输出（console.*）和未捕获错误，按时间先后排列；source 为 exception 的是未捕获错误，atlas 记录标出每次页面加载完成。记录在网页重载后仍保留，每个画框最多保留 200 条。',
    { ...frameArg, limit: { type: 'integer', minimum: 1, maximum: 200, description: '返回最近多少条，默认 50' } }, ['frame']),
  {
    name: 'frame_read',
    description: '读取画框网页当前可见内容的精简大纲：标题、文本和可交互元素；可交互元素后的 → 是可用于 frame_interact 的 CSS 选择器。最多约 20000 字。需要界面图鉴正在运行且画框已加载。',
    inputSchema: { type: 'object', properties: frameArg, required: ['frame'] },
    async run({ frame }, { socketPath }) {
      const page = await sendControl('frame_read', { frame }, { socketPath })
      const note = page.truncated ? '\n\n（内容过长，已截断）' : ''
      return { content: [{ type: 'text', text: `${page.title || '（无标题）'}\n${page.url}\n\n${page.outline}${note}` }] }
    },
  },
  canvasTool('frame_interact', 'frame_interact',
    '在画框网页中执行基础交互：click 按选择器点击；fill 向输入框、文本框、下拉框或可编辑元素填值并触发 input、change；scroll 给了 selector 时把元素滚到可见区域（同时给 deltaX/deltaY 则滚动该元素），否则按 deltaX/deltaY 滚动页面。不能点击指向其他站点或在新窗口打开的链接。',
    {
      ...frameArg,
      action: { type: 'string', enum: ['click', 'fill', 'scroll'] },
      selector: { type: 'string', description: 'CSS 选择器，可取自 frame_read' },
      value: { type: 'string', description: 'fill 时填入的值' },
      deltaX: { type: 'number' }, deltaY: { type: 'number' },
    }, ['frame', 'action']),
)

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
