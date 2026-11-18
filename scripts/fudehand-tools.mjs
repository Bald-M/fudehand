import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { sendControl } from './control-client.mjs'
import { styleTools } from './style-library.mjs'

/**
 * The only tool implementation, shared by the MCP server and the in-App Agent harness. Every tool is forwarded through the local control channel to the running App;
 * the App is the sole owner of the design document, and field validation happens in one place only, the App (Swift).
 * The style library tools are the exception: they read reference files and never touch the document (ADR 0008).
 */

const json = value => ({ content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] })

/**
 * `~` and `~/…` expand to the user's home directory; other relative paths are resolved against the
 * Fudehand source directory, so nothing depends on the App process's working directory.
 */
const absolute = (path, root) => {
  if (path === '~' || path.startsWith('~/')) return join(homedir(), path.slice(1))
  return isAbsolute(path) ? path : resolve(root, path)
}

/** Reads the PNG, JPEG, or SVG that `image.path` points to in a node (and its children) into a base64 `image.data`. */
async function inlineImages(value, root) {
  if (Array.isArray(value)) return Promise.all(value.map(item => inlineImages(item, root)))
  if (!value || typeof value !== 'object') return value
  const result = { ...value }
  if (result.image && typeof result.image === 'object' && typeof result.image.path === 'string') {
    const { path, ...image } = result.image
    let data
    try { data = await readFile(absolute(path, root)) } catch { throw new Error(`Could not read image: ${path}`) }
    result.image = { ...image, data: data.toString('base64') }
  }
  if (Array.isArray(result.children)) result.children = await inlineImages(result.children, root)
  return result
}

const NODE_GUIDE = [
  'Layer fields (coordinates are relative to the parent layer, in pt): ',
  'id (optional, generated if omitted), type (frame/rectangle/ellipse/text/image/group), name, x, y, width, height, ',
  'visible, locked, opacity (0–1), fill (#RRGGBB or #RRGGBBAA), stroke {color, width}, ',
  'cornerRadius (frame/rectangle/image), clipsContent (frame), sizing {horizontal, vertical} (fixed/hug/fill; fill only takes effect inside an auto layout parent; a group ignores fill and stretch and keeps the size of its children), ',
  'text {content, fontSize, fontWeight integer 100–900, fontFamily (a family from design_list_fonts; any other falls back to the system font), color, align left/center/right, lineHeight multiplier, autoResize none/height/width-and-height} (required for text), ',
  'image {path to a PNG, JPEG, or SVG file (~ expands to the home directory) or data (base64 of one), fit fill/fit/stretch} (required for image; an SVG stays vector and is drawn sharp at any zoom), ',
  'layout {direction vertical/horizontal, spacing, padding {top,right,bottom,left}, align start/center/end/space-between, crossAlign start/center/end/stretch} (auto layout for a frame), ',
  'interaction (prototype click interaction, any layer): {action: "navigate", destination: <top-level frame id>, transition {type none/dissolve/push-left/push-right/push-up/push-down/sheet, duration seconds 0–10 (default 0.3), easing linear/ease-in/ease-out/ease-in-out (default ease-out)}} or {action: "back"}, which returns to the previous frame playing its transition in reverse; a push names the direction the content travels (push-left brings the destination in from the right), and sheet slides it up from the bottom. ',
  'children (frame/group). Inside an auto layout frame, the layout determines the x and y of child layers.',
].join('')

function controlTool(name, command, description, properties = {}, required = Object.keys(properties), prepare) {
  return {
    name, description: `${description} Requires Fudehand to be running.`,
    inputSchema: { type: 'object', properties, required },
    async run(args, { root, socketPath }) {
      let forwarded = Object.fromEntries(Object.keys(properties).filter(key => args[key] !== undefined).map(key => [key, args[key]]))
      if (prepare) forwarded = await prepare(forwarded, root)
      return json(await sendControl(command, forwarded, { socketPath }))
    },
  }
}

const id = { id: { type: 'string', description: 'Layer id' } }
const ids = { ids: { type: 'array', items: { type: 'string' }, description: 'List of layer ids' } }
const discard = { discard: { type: 'boolean', description: 'When true, discard unsaved changes' } }
const path = description => ({ path: { type: 'string', description } })

export const tools = [
  controlTool('design_get_state', 'get_state', 'Read an overview of the design document: file, whether it has been edited, selection, viewport, whether undo is available, and a summary of top-level layers.'),
  controlTool('design_get_document', 'get_document', 'Read the full layer tree (image data is replaced by its byte count).'),
  controlTool('design_get_node', 'get_node', 'Read one layer and its child layers.', id),
  controlTool('design_create_node', 'create_node',
    `Create a layer; a whole subtree can be created at once through node.children, as a single undo step. Returns the new layer id and the result after layout. ${NODE_GUIDE}`,
    {
      node: { type: 'object', description: 'The new layer; may include children' },
      parent: { type: 'string', description: 'Parent layer id (frame or group); when omitted, the layer is placed at the top level' },
      index: { type: 'integer', minimum: 0, description: 'Position within the parent layer, 0 is the bottom; when omitted, the layer is placed on top' },
    }, ['node'],
    async (args, root) => ({ ...args, node: await inlineImages(args.node, root) })),
  controlTool('design_update_node', 'update_node',
    'Change some fields of a layer: nested objects (text, layout, stroke, sizing, image, padding) are merged field by field, interaction is replaced whole, and a null value clears that field. id, type, and children cannot be changed. Set interaction to make a layer clickable in prototype playback (see design_create_node for its fields).',
    { ...id, changes: { type: 'object', description: 'Fields to change' } }, ['id', 'changes'],
    async (args, root) => ({ ...args, changes: await inlineImages(args.changes, root) })),
  controlTool('design_delete_nodes', 'delete_nodes', 'Delete layers and their child layers, as a single undo step.', ids),
  controlTool('design_move_node', 'move_node', 'Move a layer to another parent layer or change its stacking order, keeping its position on the canvas.',
    { ...id, parent: { type: 'string', description: 'New parent layer id; when omitted, the layer moves to the top level' }, index: { type: 'integer', minimum: 0 } }, ['id']),
  controlTool('design_select', 'select', 'Select layers on the canvas (an empty array clears the selection).', ids),
  controlTool('design_undo', 'undo', 'Undo one step (human and agent edits share one history).'),
  controlTool('design_redo', 'redo', 'Redo one step.'),
  controlTool('design_new_document', 'new_document', 'Create a blank document. Refused when the current document has unsaved changes, unless discard is true.', discard, []),
  controlTool('design_open_document', 'open_document', 'Open a .fudehand project file.', { ...path('File path; ~ expands to the home directory, other relative paths are resolved against the Fudehand source directory'), ...discard }, ['path'],
    async (args, root) => ({ ...args, path: absolute(args.path, root) })),
  controlTool('design_save_document', 'save_document', 'Save the project file; when path is omitted, save to the current file.', path('Path to save as (.fudehand); ~ expands to the home directory, other relative paths are resolved against the Fudehand source directory'), [],
    async (args, root) => args.path === undefined ? args : { ...args, path: absolute(args.path, root) }),
  controlTool('canvas_focus_node', 'focus_node', 'Move and zoom the viewport to the given layer.', id),
  controlTool('canvas_fit_all', 'fit_all', 'Zoom the viewport to show all layers.'),
  controlTool('canvas_zoom', 'zoom', 'Zoom to the given scale around the center of the canvas (1 is actual size, range 0.05–4).', { scale: { type: 'number' } }),
  controlTool('design_list_fonts', 'list_fonts', 'List the font families that text.fontFamily can use: those installed on this Mac (source system) and those imported into the Fudehand font library (source imported).'),
  controlTool('design_import_font', 'import_font', 'Import a font file (.ttf, .otf, or .ttc) into the Fudehand font library, which makes it available to Fudehand only, and return its font families.',
    path('Font file path; ~ expands to the home directory, other relative paths are resolved against the Fudehand source directory'), ['path'],
    async (args, root) => ({ ...args, path: absolute(args.path, root) })),
  {
    name: 'design_snapshot',
    description: 'Capture a layer (usually a frame) as a PNG exactly as the App renders it, to check the result. Requires Fudehand to be running.',
    inputSchema: { type: 'object', properties: { ...id, scale: { type: 'number', minimum: 0.1, maximum: 4, description: 'Pixel scale, default 2' } }, required: ['id'] },
    async run(args, { socketPath }) {
      const shot = await sendControl('node_snapshot', { id: args.id, ...(args.scale === undefined ? {} : { scale: args.scale }) }, { socketPath })
      return { content: [
        { type: 'image', data: shot.data, mimeType: shot.mimeType },
        { type: 'text', text: `Snapshot of layer ${shot.id} (${shot.width}×${shot.height})` },
      ] }
    },
  },
  ...styleTools,
]

/** Calls a tool; any error becomes an error result carrying its message instead of being thrown. */
export async function callTool(name, args, ctx) {
  const tool = tools.find(item => item.name === name)
  try {
    if (!tool) throw new Error(`Unknown tool: ${name}`)
    return await tool.run(args ?? {}, ctx)
  } catch (error) {
    return { isError: true, content: [{ type: 'text', text: error instanceof Error ? error.message : String(error) }] }
  }
}
