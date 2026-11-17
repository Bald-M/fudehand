import { readFile } from 'node:fs/promises'
import { isAbsolute, resolve } from 'node:path'
import { sendControl } from './control-client.mjs'

/**
 * MCP server 与 App 内 Agent harness 共用的唯一工具实现。所有工具经本地控制通道转发给正在运行的 App；
 * App 是设计文档的唯一持有者，字段校验只在 App（Swift）一处。
 */

const json = value => ({ content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] })

/** 相对路径按 ui-atlas 源码目录解析，避免依赖 App 进程的工作目录。 */
const absolute = (path, root) => isAbsolute(path) ? path : resolve(root, path)

/** 把节点（及子节点）中 `image.path` 指向的 PNG/JPEG 读成 base64 的 `image.data`。 */
async function inlineImages(value, root) {
  if (Array.isArray(value)) return Promise.all(value.map(item => inlineImages(item, root)))
  if (!value || typeof value !== 'object') return value
  const result = { ...value }
  if (result.image && typeof result.image === 'object' && typeof result.image.path === 'string') {
    const { path, ...image } = result.image
    let data
    try { data = await readFile(absolute(path, root)) } catch { throw new Error(`无法读取图片：${path}`) }
    result.image = { ...image, data: data.toString('base64') }
  }
  if (Array.isArray(result.children)) result.children = await inlineImages(result.children, root)
  return result
}

const NODE_GUIDE = [
  '图层字段（坐标相对父图层，单位 pt）：',
  'id（可省略，自动生成）、type（frame/rectangle/ellipse/text/image/group）、name、x、y、width、height、',
  'visible、locked、opacity（0–1）、fill（#RRGGBB 或 #RRGGBBAA）、stroke {color, width}、',
  'cornerRadius（frame/rectangle/image）、clipsContent（frame）、sizing {horizontal, vertical}（fixed/hug/fill；fill 只在自动布局父图层中生效）、',
  'text {content, fontSize, fontWeight 100–900, fontFamily, color, align left/center/right, lineHeight 倍数, autoResize none/height/width-and-height}（text 必填）、',
  'image {path 或 data（base64）, fit fill/fit/stretch}（image 必填）、',
  'layout {direction vertical/horizontal, spacing, padding {top,right,bottom,left}, align start/center/end/space-between, crossAlign start/center/end/stretch}（frame 的自动布局）、',
  'children（frame/group）。自动布局画框里子图层的 x、y 由布局决定。',
].join('')

function controlTool(name, command, description, properties = {}, required = Object.keys(properties), prepare) {
  return {
    name, description: `${description}需要 ui-atlas 正在运行。`,
    inputSchema: { type: 'object', properties, required },
    async run(args, { root, socketPath }) {
      let forwarded = Object.fromEntries(Object.keys(properties).filter(key => args[key] !== undefined).map(key => [key, args[key]]))
      if (prepare) forwarded = await prepare(forwarded, root)
      return json(await sendControl(command, forwarded, { socketPath }))
    },
  }
}

const id = { id: { type: 'string', description: '图层 id' } }
const ids = { ids: { type: 'array', items: { type: 'string' }, description: '图层 id 列表' } }
const discard = { discard: { type: 'boolean', description: '为 true 时放弃未保存的修改' } }
const path = description => ({ path: { type: 'string', description } })

export const tools = [
  controlTool('design_get_state', 'get_state', '读取设计文档概况：文件、是否已编辑、选择、视口、可否撤销，以及顶层图层摘要。'),
  controlTool('design_get_document', 'get_document', '读取完整图层树（图片数据以字节数代替）。'),
  controlTool('design_get_node', 'get_node', '读取一个图层及其子图层。', id),
  controlTool('design_create_node', 'create_node',
    `新建图层，可在 node.children 中一次创建整棵子树，作为一步撤销。返回新图层 id 与布局后的结果。${NODE_GUIDE}`,
    {
      node: { type: 'object', description: '新图层，可含 children' },
      parent: { type: 'string', description: '父图层 id（frame 或 group）；省略时放在顶层' },
      index: { type: 'integer', minimum: 0, description: '在父图层中的位置，0 为最下层；省略时放在最上层' },
    }, ['node'],
    async (args, root) => ({ ...args, node: await inlineImages(args.node, root) })),
  controlTool('design_update_node', 'update_node',
    '修改图层的部分字段：嵌套对象（text、layout、stroke、sizing、image、padding）逐字段合并，值为 null 时清除该字段。不能修改 id、type、children。',
    { ...id, changes: { type: 'object', description: '要修改的字段' } }, ['id', 'changes'],
    async (args, root) => ({ ...args, changes: await inlineImages(args.changes, root) })),
  controlTool('design_delete_nodes', 'delete_nodes', '删除图层及其子图层，作为一步撤销。', ids),
  controlTool('design_move_node', 'move_node', '把图层移到另一个父图层或调整层叠顺序，保持画布上的位置。',
    { ...id, parent: { type: 'string', description: '新父图层 id；省略时移到顶层' }, index: { type: 'integer', minimum: 0 } }, ['id']),
  controlTool('design_select', 'select', '在画布上选中图层（空数组取消选择）。', ids),
  controlTool('design_undo', 'undo', '撤销一步（人工与 Agent 的修改共用历史）。'),
  controlTool('design_redo', 'redo', '重做一步。'),
  controlTool('design_new_document', 'new_document', '新建空白文档。当前文档有未保存修改时拒绝，除非 discard 为 true。', discard, []),
  controlTool('design_open_document', 'open_document', '打开 .uiatlas 工程文件。', { ...path('文件路径，相对路径按 ui-atlas 源码目录解析'), ...discard }, ['path'],
    async (args, root) => ({ ...args, path: absolute(args.path, root) })),
  controlTool('design_save_document', 'save_document', '保存工程文件；省略 path 时保存到当前文件。', path('另存为的路径（.uiatlas），相对路径按 ui-atlas 源码目录解析'), [],
    async (args, root) => args.path === undefined ? args : { ...args, path: absolute(args.path, root) }),
  controlTool('canvas_focus_node', 'focus_node', '把视口移动并缩放到指定图层。', id),
  controlTool('canvas_fit_all', 'fit_all', '缩放视口以显示全部图层。'),
  controlTool('canvas_zoom', 'zoom', '以画布中心为基准缩放到指定比例（1 为实际大小，范围 0.05～4）。', { scale: { type: 'number' } }),
  {
    name: 'design_snapshot',
    description: '把图层（通常是一个画框）按 App 中的实际渲染截成 PNG，用于核对效果。需要 ui-atlas 正在运行。',
    inputSchema: { type: 'object', properties: { ...id, scale: { type: 'number', minimum: 0.1, maximum: 4, description: '像素倍率，默认 2' } }, required: ['id'] },
    async run(args, { socketPath }) {
      const shot = await sendControl('node_snapshot', { id: args.id, ...(args.scale === undefined ? {} : { scale: args.scale }) }, { socketPath })
      return { content: [
        { type: 'image', data: shot.data, mimeType: shot.mimeType },
        { type: 'text', text: `图层 ${shot.id} 的截图（${shot.width}×${shot.height}）` },
      ] }
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
