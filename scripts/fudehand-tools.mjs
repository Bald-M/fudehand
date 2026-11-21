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

/** Replaces `image.path` in an object (a layer or a texture effect) with the base64 `image.data` of the file it points to. */
async function inlineImage(value, root) {
  if (!value || typeof value !== 'object' || !value.image || typeof value.image !== 'object' || typeof value.image.path !== 'string') return value
  const { path, ...image } = value.image
  let data
  try { data = await readFile(absolute(path, root)) } catch { throw new Error(`Could not read image: ${path}`) }
  return { ...value, image: { ...image, data: data.toString('base64') } }
}

/** Reads the PNG, JPEG, or SVG that `image.path` points to in a node, its texture effects, and its children into base64 `image.data`. */
async function inlineImages(value, root) {
  if (Array.isArray(value)) return Promise.all(value.map(item => inlineImages(item, root)))
  if (!value || typeof value !== 'object') return value
  const result = await inlineImage(value, root)
  if (Array.isArray(result.effects)) result.effects = await Promise.all(result.effects.map(effect => inlineImage(effect, root)))
  if (Array.isArray(result.children)) result.children = await inlineImages(result.children, root)
  return result
}

const NODE_GUIDE = [
  'Layer fields (coordinates are relative to the parent layer, in pt): ',
  'id (optional, generated if omitted), type (frame/rectangle/ellipse/text/image/icon/group), name, x, y, width, height, ',
  'visible, locked, opacity (0–1), fill (#RRGGBB or #RRGGBBAA), stroke {color, width}, ',
  'effects (any layer but group): an array drawn in order, later ones on top, of {type drop-shadow/inner-shadow/layer-blur/background-blur/noise/texture/glass/shader/transform-3d/perspective, visible (default true), radius (blur in pt, 0–250, default 4, 20 for glass; for shadows, blurs, and glass)}; a shadow also takes color (default #00000040), x and y offset in pt (default 0 and 4), and spread in pt (default 0; grows the shape, ignored by text and icons). Shadows follow the layer\'s shape, or the glyphs of text and icons; a drop shadow is not drawn under the layer. layer-blur blurs the layer with its children; background-blur blurs the layers under it in the same parent, seen through a see-through fill (e.g. frosted glass). noise (frame/rectangle/ellipse only) draws grain over the layer\'s area, above its fill and below its children, clipped to its shape: color (default #00000033; its alpha is the strength), size (grain side in pt, 0.5–8, default 1), density (share of grains drawn, 0–1, default 0.5), and seed (integer ≥ 0, default 0; the same seed always gives the same grains). texture (frame/rectangle/ellipse only) repeats an image over the layer\'s area from its top-left corner, in the same place as noise: image {path to a PNG, JPEG, or SVG file or data (base64 of one)} (required), size (tile width in pt, 4–1024, default 64; the height follows the image), opacity (0–1, default 1), and blend (normal/multiply/screen/overlay/soft-light, default normal; blends with the layer\'s fill). design_get_node shows a texture\'s image.data as "<N bytes>"; sending it back unchanged in design_update_node, at the same place in effects, keeps the image. glass (frame/rectangle/ellipse only; at most one per layer, never with background-blur) is frosted glass: like background-blur it blurs the layers under it in the same parent (radius), first boosting their colors by saturation (0–2, default 1.4; 1 leaves them), then draws tint over them (default #FFFFFF33; its alpha is the strength) and a light edge along the inside of the top of the shape with opacity highlight (0–1, default 0.5); give the layer a see-through or no fill. shader (frame/rectangle/ellipse only) draws one of Fudehand\'s built-in shaders over the layer\'s area, in the same place as noise: shader (an id from design_list_shaders; required), params (an object of that shader\'s parameters, numbers or #RRGGBB(AA) colors; ones left out take their defaults), opacity (0–1, default 1), and blend (as for texture); shaders are static images, not animated. transform-3d (Beta; any layer but group; at most one) turns the layer and its effects in 3D about its center, as CSS rotateX() rotateY() translateZ(): rotateX and rotateY in degrees (−80–80, default 0; positive rotateX tips the top edge away, positive rotateY turns the right edge away) and translateZ in pt (−1000–1000, default 0; positive comes toward the viewer). perspective (Beta; frames only; at most one) is how the frame\'s direct children are seen, as CSS perspective and perspective-origin: distance in pt (100–10000, default 800) and originX, originY as fractions of the frame (0–1, default 0.5); without it a turned layer is projected flat. Both are visual only: layout, selection, and hit testing use the unturned rectangle. Put turned layers directly in the frame with the perspective (inside a group they are drawn flat), and snapshot that frame rather than a turned child, which on its own is drawn flat. ',
  'cornerRadius (frame/rectangle/image), clipsContent (frame), sizing {horizontal, vertical} (fixed/hug/fill; fill only takes effect inside an auto layout parent; a group ignores fill and stretch and keeps the size of its children), ',
  'text {content, fontSize, fontWeight integer 100–900, fontFamily (a family from design_list_fonts; any other falls back to the system font), color, align left/center/right, lineHeight multiplier, autoResize none/height/width-and-height} (required for text), ',
  'image {path to a PNG, JPEG, or SVG file (~ expands to the home directory) or data (base64 of one), fit fill/fit/stretch} (required for image; an SVG stays vector and is drawn sharp at any zoom), ',
  'icon {name "<library>/<name>" as returned by design_search_icons, color (default #000000)} (required for icon; a single-color vector icon drawn to fit width and height, default 24×24; an unknown name is an error that lists similar names). Use real icons rather than shapes or words standing in for them. ',
  'layout {direction vertical/horizontal, spacing, padding {top,right,bottom,left}, align start/center/end/space-between, crossAlign start/center/end/stretch} (auto layout for a frame), ',
  'interaction (prototype click interaction, any layer; transition is {type none/dissolve/push-left/push-right/push-up/push-down/sheet, duration seconds 0–10 (default 0.3), easing linear/ease-in/ease-out/ease-in-out (default ease-out)}): ',
  '{action: "navigate", destination: <top-level frame id>, transition}; {action: "back"}, which returns to the previous frame playing its transition in reverse (or closes the topmost overlay when one is open); ',
  '{action: "open-overlay", destination: <top-level frame id>, position center/bottom/below-trigger (default center; below-trigger puts it under the clicked layer), background (#RRGGBBAA scrim drawn over the frame below; omit for none), closeOnOutsideClick (default true), transition}, which shows that frame over the current one, where only it takes input; ',
  '{action: "close-overlay"}, which closes the topmost overlay; {action: "toggle-visibility", targets: [layer ids]}, which shows the hidden and hides the shown among those layers for this playback only (tabs, switches, checkboxes, expand/collapse). ',
  'A push names the direction the content travels (push-left brings the destination in from the right), and sheet slides it up from the bottom. Navigating from an overlay closes it first. ',
  'scroll (frame): none/vertical/horizontal; in playback the frame\'s overflowing content scrolls with the wheel or trackpad. fixedOnScroll (true on a direct child of a scrolling frame): the layer stays in place above the scrolled content, e.g. a navigation bar or tab bar. ',
  'states {hover {fill, opacity}, pressed {fill, opacity}}: how the layer looks in playback while the pointer is over it and while it is pressed (pressed applies on top of hover); omitted fields keep the layer\'s own. ',
  'animation (prototype animation, any layer; plays when the layer\'s frame appears in the prototype window, never on the canvas or in snapshots): {type fade-in/slide-in/scale-in (entrances) or spin/pulse/shimmer (loops), duration seconds >0–60 (one cycle for a loop; default 0.3 for entrances, 1 for spin and pulse, 1.5 for shimmer), delay seconds 0–60 (default 0), easing linear/ease-in/ease-out/ease-in-out (default ease-out for entrances, ease-in-out for pulse, linear otherwise), repeat integer 1–1000 or "infinite" (default 1 for entrances, "infinite" for loops); slide-in only: from left/right/top/bottom (default bottom) and distance pt (default 40); pulse only: property scale/opacity (default scale)}. slide-in and scale-in also fade in; spin turns clockwise about the center; shimmer sweeps a see-through band across the layer (skeleton loading). ',
  'text.sequence (text sequence, text layers): {items: array of 1–1000 strings shown in turn during playback, interval seconds 0.05–3600 (default 1), loop true/false (default false: stays on the last item)}, e.g. a countdown; text.content is what the canvas and snapshots show. ',
  'versionSnapshot (image layers that are version snapshots, made by design_save_version_snapshot): {frame <id of the frame it was taken of>, createdAt ISO 8601, note}; change the note with design_update_node. ',
  'layoutGuides (frame): an array of layout guides drawn over the frame on the editing canvas only (never in snapshots or playback); layers moved or resized inside the frame snap to the edges of its visible columns and rows. ',
  'Each is {type grid/columns/rows, color (default #FF00001A), visible (default true)}; a grid adds size pt (default 10); columns and rows add count integer 1–1000 (default 5), align stretch/start/center/end (default stretch), width pt (start/center/end only; a column\'s width or a row\'s height, default 60), gutter pt (default 20), and margin pt from the frame edge (default 0, ignored by center). ',
  'children (frame/group). Inside an auto layout frame, the layout determines the x and y of child layers.',
].join('')

function controlTool(name, command, description, properties = {}, required = Object.keys(properties), prepare) {
  return {
    name, description: `${description} Requires Fudehand to be running.`,
    inputSchema: { type: 'object', properties, required },
    async run(args, { root, socketPath, conversation }) {
      let forwarded = Object.fromEntries(Object.keys(properties).filter(key => args[key] !== undefined).map(key => [key, args[key]]))
      if (prepare) forwarded = await prepare(forwarded, root)
      return json(await sendControl(command, forwarded, { socketPath, caller: conversation }))
    },
  }
}

const id = { id: { type: 'string', description: 'Layer id' } }
const ids = { ids: { type: 'array', items: { type: 'string' }, description: 'List of layer ids' } }
const discard = { discard: { type: 'boolean', description: 'When true, discard unsaved changes' } }
const path = description => ({ path: { type: 'string', description } })
const conversation = { id: { type: 'string', description: 'Conversation id from chat_list_conversations; when omitted, the selected conversation' } }
const openConversation = { id: { type: 'string', description: 'Conversation id from chat_list_conversations' } }
const context = { context: { type: 'array', items: { type: 'string' }, description: 'Ids of layers to attach as context tags, as the selected layers are in the panel; when omitted, none' } }
const ownConversation = 'Refused for the conversation whose Agent is calling.'
const sent = 'The reply runs on in the App: read its progress and result with chat_get_conversation.'
const provider = { provider: { type: 'string', enum: ['deepseek', 'anthropic', 'openai'], description: 'Model provider: deepseek (DeepSeek), anthropic (Claude), or openai (ChatGPT)' } }

export const tools = [
  controlTool('design_get_state', 'get_state', 'Read an overview of the design document: file, whether it has been edited, selection, viewport, the editor view (canvas tool, inspector, collapsed layers), whether undo is available, and a summary of top-level layers.'),
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
    'Change some fields of a layer: nested objects (text, layout, stroke, sizing, image, padding, versionSnapshot) are merged field by field, interaction, animation, states, effects, and text.sequence are replaced whole, and a null value clears that field; the layoutGuides array is replaced whole. id, type, and children cannot be changed. Set interaction, states, scroll, or fixedOnScroll to make a layer interactive in prototype playback, and animation or text.sequence to make it move (see design_create_node for their fields).',
    { ...id, changes: { type: 'object', description: 'Fields to change' } }, ['id', 'changes'],
    async (args, root) => ({ ...args, changes: await inlineImages(args.changes, root) })),
  controlTool('design_delete_nodes', 'delete_nodes', 'Delete layers and their child layers, as a single undo step.', ids),
  controlTool('design_copy_nodes', 'copy_nodes',
    'Copy layers with their child layers to the clipboard, as Edit > Copy does; with cut true also delete them, as one undo step (Edit > Cut). Paste them with design_paste, also into another document. Returns the ids copied (a layer copied with its ancestor goes with the ancestor).',
    { ids: { ...ids.ids, description: 'Layer ids; when omitted, the current selection' }, cut: { type: 'boolean', description: 'When true, delete the layers after copying them' } }, []),
  controlTool('design_paste', 'paste',
    'Paste the layers on the clipboard as Edit > Paste does, as one undo step: new ids, selected afterwards. With one frame selected (not one of the copied layers or an earlier paste) they go into it; otherwise beside the originals in their parent, 10 points further down and right with each paste (in place right after a cut), or centered in the viewport when that place is out of view. Returns ids and nodes of the new layers.'),
  controlTool('design_duplicate_nodes', 'duplicate_nodes',
    'Duplicate layers with their child layers as Edit > Duplicate does, as one undo step: each copy goes just above its original, 10 points down and right, with new ids, and the copies are selected. The clipboard is unchanged. Returns ids and nodes of the new layers.',
    { ids: { ...ids.ids, description: 'Layer ids; when omitted, the current selection' } }, []),
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
  controlTool('canvas_focus_node', 'focus_node', 'Move and zoom the viewport to fit the given layer, or several layers together (the same as Zoom to Selection). Pass id or ids. Returns the state, including the new viewport.',
    { id: { type: 'string', description: 'Layer id' }, ids: { type: 'array', items: { type: 'string' }, minItems: 1, description: 'Several layer ids to fit together' } }, []),
  controlTool('canvas_fit_all', 'fit_all', 'Zoom the viewport to show all layers.'),
  controlTool('canvas_zoom', 'zoom', 'Zoom to the given scale around the center of the canvas (1 is actual size, range 0.05–4).', { scale: { type: 'number' } }),
  controlTool('canvas_set_view', 'set_view',
    'Change the editor view: the canvas tool, whether the inspector is shown and which tab it shows, and which layers the layers panel collapses. Pass only what should change. Not part of the undo history: returns the previous view and the new view. The current view is also in design_get_state (view).',
    {
      tool: { type: 'string', enum: ['move', 'hand', 'frame', 'rectangle', 'ellipse', 'text', 'annotate'], description: 'Canvas tool' },
      inspector: { type: 'boolean', description: 'Show (true) or hide (false) the inspector' },
      inspectorTab: { type: 'string', enum: ['design', 'prototype', 'chat'], description: 'Inspector tab: design is the properties panel, prototype the interaction settings of the selected layer, chat the chat panel' },
      expand: { type: 'array', items: { type: 'string' }, description: 'Ids of layers with child layers to expand in the layers panel' },
      collapse: { type: 'array', items: { type: 'string' }, description: 'Ids of layers with child layers to collapse in the layers panel' },
    }, []),
  controlTool('prototype_play', 'play',
    'Open the prototype window and play the design document from a top-level frame, as Play Prototype does; playing again restarts. ' +
    'Without frame it starts from the top-level frame holding the selection, otherwise the first top-level frame. Returns the prototype window state (see prototype_get_playback).',
    { frame: { type: 'string', description: 'Id of the top-level frame to start from; omit to start where Play Prototype starts' } }, []),
  controlTool('prototype_get_playback', 'get_playback',
    'Read the prototype window state: open (whether the window is open), frame and name (the id and name of the top-level frame on show; null when the window is closed or that frame was deleted).'),
  controlTool('prototype_close', 'close', 'Close the prototype window. Returns the prototype window state.'),
  controlTool('design_list_shaders', 'list_shaders', 'List the built-in shaders a shader effect can draw: each one\'s id, name, description, and parameters (name, kind number or color, default, and for numbers min and max). Only these can be drawn; there is no way to supply shader code.'),
  controlTool('design_list_fonts', 'list_fonts', 'List the font families that text.fontFamily can use: those installed on this Mac (source system) and those imported into the Fudehand font library (source imported).'),
  controlTool('design_import_font', 'import_font', 'Import a font file (.ttf, .otf, or .ttc) into the Fudehand font library, which makes it available to Fudehand only, and return its font families.',
    path('Font file path; ~ expands to the home directory, other relative paths are resolved against the Fudehand source directory'), ['path'],
    async (args, root) => ({ ...args, path: absolute(args.path, root) })),
  controlTool('design_search_icons', 'search_icons',
    'Search the built-in icon libraries by keywords (matched against icon names and, for Lucide and SF Symbols, their tags; case, word order, and the separators space - _ . do not matter) and return icon names for an icon layer. ' +
    'Pick the library by the prototype\'s target platform: sf (SF Symbols) for iOS and macOS, one material-outlined/material-rounded/material-sharp style for Android, weui for a WeChat mini program, lucide for the web; keep one library and style per screen. ' +
    'Material fill variants end in .fill (material-rounded/home.fill). SF Symbols are licensed by Apple for mockups of apps on Apple platforms only.',
    {
      query: { type: 'string', description: 'Keyword, e.g. home, search, arrow' },
      library: { type: 'string', enum: ['sf', 'material-outlined', 'material-rounded', 'material-sharp', 'weui', 'lucide'], description: 'Search only this library' },
      limit: { type: 'integer', minimum: 1, maximum: 200, description: 'Maximum number of names, default 50' },
    }, ['query']),
  controlTool('design_list_colors', 'list_colors',
    'Read the selection colors: every color used by the fills, strokes, text colors, and icon colors of the given layers and all their child layers, merged by hex value, most used first. Returns ids and colors [{color, count}].',
    { ids: { ...ids.ids, description: 'Layer ids; when omitted, the current selection' } }, []),
  controlTool('design_replace_color', 'replace_color',
    'Replace a selection color: every fill, stroke, text color, and icon color of the given layers and their child layers that uses from becomes to, as a single undo step. Fails, changing nothing, when no layer there uses from. Returns replaced (how many properties changed) and the new selection colors.',
    {
      from: { type: 'string', description: 'The color to replace, #RRGGBB or #RRGGBBAA (as returned by design_list_colors)' },
      to: { type: 'string', description: 'The new color, #RRGGBB or #RRGGBBAA' },
      ids: { ...ids.ids, description: 'Layer ids; when omitted, the current selection' },
    }, ['from', 'to']),
  controlTool('design_save_version_snapshot', 'save_version_snapshot',
    'Save a version snapshot of a frame, as one undo step: the frame as it looks now, rendered into a read-only top-level image layer placed to the right of the frame and of its earlier snapshots, top-aligned with it. ' +
    'Use it before changing a frame substantially so the old and new versions can be compared side by side, or overlaid by moving the snapshot to the frame\'s position (frameBounds) and lowering its opacity with design_update_node. ' +
    'Returns the snapshot as design_list_version_snapshots lists it; delete one with design_delete_nodes.',
    { frame: { type: 'string', description: 'Id of the frame to snapshot' }, note: { type: 'string', description: 'Optional note saved with the snapshot, e.g. what is about to change' } }, ['frame']),
  controlTool('design_list_version_snapshots', 'list_version_snapshots',
    'List the version snapshots in the document, oldest first, or only those of one frame: id, name, frame and frameName (null once the frame is deleted), createdAt, note, opacity, and the snapshot\'s and the frame\'s bounds in canvas coordinates.',
    { frame: { type: 'string', description: 'Only snapshots of this frame id' } }, []),
  controlTool('design_list_annotations', 'list_annotations',
    'List annotations: plain-text notes people and agents pin to a point inside a layer, each with its replies. Annotations are not layers: they are not in the layer tree or in snapshots. ' +
    'Returns {annotations: [{id, node (layer id), x, y (relative to the layer\'s top-left corner, in pt), author person/agent, text, replies: [{id, author, text}]}]}, in the order added.',
    { node: { type: 'string', description: 'Only the annotations on this layer; when omitted, all annotations' } }, []),
  controlTool('design_add_annotation', 'add_annotation',
    'Pin a new annotation to a layer, or reply to one with replyTo. Annotations are saved in the project file, follow their layer when it moves, are deleted with it, and each addition is one undo step. Returns the whole annotation with its replies.',
    {
      node: { type: 'string', description: 'Layer id to pin a new annotation to' },
      x: { type: 'number', description: 'Point inside the layer, relative to its top-left corner (pt); kept inside the layer. Default: the layer\'s center' },
      y: { type: 'number', description: 'See x' },
      text: { type: 'string', description: 'Plain text; must not be empty' },
      replyTo: { type: 'string', description: 'Annotation id (or the id of one of its replies) to reply to, instead of node, x, and y' },
    }, ['text']),
  controlTool('design_update_annotation', 'update_annotation', 'Replace the text of an annotation or a reply, as one undo step. Returns the whole annotation.',
    { id: { type: 'string', description: 'Annotation or reply id' }, text: { type: 'string', description: 'New plain text; must not be empty' } }),
  controlTool('design_delete_annotation', 'delete_annotation', 'Delete an annotation with all its replies, or a single reply, as one undo step.',
    { id: { type: 'string', description: 'Annotation or reply id' } }),
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
  controlTool('design_export_html', 'export_html',
    'Export a layer (usually a frame) as a reference web page for implementing the design in front-end code, as File > Export as HTML… does: writes index.html (one CSS class per layer; auto layout becomes flexbox, other children are placed absolutely; each element carries data-layer-id) and its images and icons under assets/. ' +
    'Icons are drawn through a CSS mask tinted with the icon color; SF Symbols are written as PNG, other icons as SVG. Hidden layers and prototype settings are left out, and fonts keep their macOS family names. ' +
    'The directory is created when missing and must otherwise be empty. Returns the files written (relative to the directory), the asset file of each image and icon layer, and the HTML; the document is not changed. Adapt the result to the target project\'s framework and styles rather than copying it.',
    { ...id, directory: { type: 'string', description: 'Directory to write into; prefer an absolute path. ~ expands to the home directory, other relative paths are resolved against the Fudehand source directory' } },
    ['id', 'directory'],
    async (args, root) => ({ ...args, directory: absolute(args.directory, root) })),
  controlTool('app_show_launch_window', 'show_launch_window', 'Show the launch window (New, Recent, Templates) in front, as Window > Launch Window does; the editor window and the document stay as they are. Returns the document overview.'),
  controlTool('app_close_editor_window', 'close_editor_window', 'Close the editor window, as its close button or File > Close does: the prototype window closes too, the launch window shows, and the App keeps running with a new, empty, untitled document. Refused when the current document has unsaved changes, unless discard is true. Returns the document overview.',
    discard, []),
  controlTool('app_list_recents', 'list_recents', 'List the recent files shown in the launch window and File > Open Recent, newest first: path, name, openedAt (ISO 8601), and available (false when the file was deleted or moved).'),
  controlTool('app_open_recent', 'open_recent', 'Open a project file from the recent files, by its path as app_list_recents returns it. Refused when the file was deleted or moved, or when the current document has unsaved changes, unless discard is true. Returns the document overview.',
    { ...path('Path of a recent file, as returned by app_list_recents'), ...discard }, ['path'],
    async (args, root) => ({ ...args, path: absolute(args.path, root) })),
  controlTool('app_remove_recent', 'remove_recent', 'Remove one file from the recent files (the file itself is not touched). Returns the removed path and the remaining list.',
    path('Path of a recent file, as returned by app_list_recents'), ['path'],
    async (args, root) => ({ ...args, path: absolute(args.path, root) })),
  controlTool('app_clear_recents', 'clear_recents', 'Clear the recent files (the files themselves are not touched). Returns the removed paths and the now empty list.'),
  controlTool('app_list_templates', 'list_templates', 'List the templates bundled with Fudehand, shown in the launch window: each has a name (pass it to app_new_document_from_template) and the title the launch window shows in the current UI language.'),
  controlTool('app_new_document_from_template', 'new_document_from_template', 'Create an untitled design document from a template, as the launch window does: the document is not linked to the template file, so saving it needs a path and never overwrites the template. Refused when the current document has unsaved changes, unless discard is true. Returns the document overview.',
    { name: { type: 'string', description: 'Template name, as returned by app_list_templates' }, ...discard }, ['name']),
  controlTool('chat_list_conversations', 'list_conversations',
    'List the conversations of the current design document in the chat panel: the open tabs in order (with whether each is replying, waiting for an answer, its mode, and its model), the selected one, and the saved conversations of the history menu, newest first.'),
  controlTool('chat_get_conversation', 'get_conversation',
    'Read a conversation, open or saved: its messages, tool calls, errors, and question cards (with their options and answer), whether it is replying or waiting for an answer, its mode, the tokens it takes up in the context window (contextTokens), and the predicted next message (suggestion).',
    conversation, []),
  controlTool('chat_open_conversation', 'open_conversation',
    'Open a conversation in the chat panel and select its tab: switches to it when it is already open, otherwise reopens it from the history. Returns the conversation list.', openConversation),
  controlTool('chat_new_conversation', 'new_conversation',
    'Start an empty conversation in a new tab with the selected conversation\'s model, or select the empty tab that is already open. Returns the conversation list, whose selected id is the new conversation.'),
  controlTool('chat_close_conversation', 'close_conversation',
    `Close a conversation's tab, stopping its reply; it stays in the history. ${ownConversation} Returns the conversation list.`, openConversation),
  controlTool('chat_delete_conversation', 'delete_conversation',
    `Delete a conversation from the history and close its tab. Refused while it is replying. ${ownConversation} Returns the conversation list.`, openConversation),
  controlTool('chat_clear_conversation', 'clear_conversation',
    `Empty an open conversation in place, as /clear does, stopping its reply. ${ownConversation} Returns the conversation.`, conversation, []),
  controlTool('chat_send_message', 'send_message',
    `Send a message to an open conversation, selecting its tab, and start the Agent's reply. mode switches the conversation first, as /plan and /goal do: plan has the Agent reply with a plan and change nothing until a later message confirms it; goal makes the message a goal the Agent works on until it is done. Refused while the conversation is replying or waiting for an answer to a question. ${ownConversation} ${sent}`,
    {
      ...conversation, text: { type: 'string', description: 'The message' }, ...context,
      mode: { type: 'string', enum: ['plan', 'goal'], description: 'Switch the conversation into this mode before sending; when omitted, the conversation keeps its mode' },
    }, ['text']),
  controlTool('chat_set_mode', 'set_mode',
    `Switch an open conversation into plan or goal mode for its next messages, or leave the mode with none, as the mode tag in the panel does. ${ownConversation} Returns the conversation.`,
    { ...conversation, mode: { type: 'string', enum: ['plan', 'goal', 'none'], description: 'plan, goal, or none to leave the mode' } }, ['mode']),
  controlTool('chat_run_plan', 'run_plan',
    `Confirm the plan an open conversation made in plan mode, as Run Plan does: leaves plan mode and asks the Agent to carry the plan out. Refused when no plan is waiting (planReady in chat_get_conversation). ${ownConversation} ${sent}`,
    { ...conversation, ...context }, []),
  controlTool('chat_stop_reply', 'stop_reply',
    `Stop an open conversation's reply, keeping what it produced so far and cancelling a question it is waiting on. ${ownConversation} Returns the conversation.`, conversation, []),
  controlTool('chat_regenerate_reply', 'regenerate_reply',
    `Send the last message of an open conversation again, replacing the reply it got. Refused while it is replying. ${ownConversation} ${sent}`, conversation, []),
  controlTool('chat_edit_last_message', 'edit_last_message',
    `Replace the last message of an open conversation, and the reply it got, with new text, and send it. Refused while it is replying. ${ownConversation} ${sent}`,
    { ...conversation, text: { type: 'string', description: 'The new message' }, ...context }, ['text']),
  controlTool('chat_answer_question', 'answer_question',
    `Answer the question card an open conversation is waiting on, with text (one of its option labels or any other answer), or skip it with skip: true to leave the choice to the Agent; the reply then continues. ${ownConversation} ${sent}`,
    { ...conversation, text: { type: 'string', description: 'The answer' }, skip: { type: 'boolean', description: 'Skip the question instead of answering it' } }, []),
  controlTool('chat_compact_conversation', 'compact_conversation',
    `Compact an open conversation, as /compact does: the Agent summarizes it and carries on from the summary, freeing context; the messages stay visible. Refused while it is replying. ${ownConversation} ${sent}`,
    conversation, []),
  controlTool('settings_get_interface', 'get_interface', 'Read the UI language and the appearance (system, light, or dark), with the values each one accepts.'),
  controlTool('settings_update_interface', 'update_interface',
    'Change the UI language and/or the appearance, as the App menus do. Settings are not undoable: returns the new values and the previous ones. Items macOS itself adds to the menus change language only after Fudehand restarts.',
    {
      language: { type: 'string', enum: ['en-US', 'en-GB', 'zh-Hans', 'zh-Hant'], description: 'UI language' },
      appearance: { type: 'string', enum: ['system', 'light', 'dark'], description: 'Appearance; system follows macOS' },
    }, []),
  controlTool('settings_get_models', 'get_models',
    'Read the chat panel\'s model providers: for each one its base URL, model (empty means the provider\'s default model), cached model list, whether an API key is saved and its masked hint, and which provider the selected conversation uses. API keys themselves are never returned.'),
  controlTool('settings_update_model_provider', 'update_model_provider',
    'Change a model provider\'s base URL and/or model as the Model Settings sheet does, and optionally make it the provider the selected conversation uses (it needs a saved API key). An empty model means the provider\'s default model; an empty base URL means its official endpoint. Returns the provider and the previous values; the change applies from the next message.',
    {
      ...provider,
      model: { type: 'string', description: 'Model id; empty for the provider\'s default model' },
      baseUrl: { type: 'string', description: 'Base URL; empty for the official endpoint' },
      use: { type: 'boolean', description: 'When true, the selected conversation uses this provider' },
    }, ['provider']),
  controlTool('settings_list_models', 'list_models',
    'Fetch a provider\'s model list with its saved API key, which also tests the connection, and cache it for the model menu. Returns the models, the provider\'s default model, and the previously cached list; fails with the provider\'s error when the key or endpoint does not work.',
    { ...provider, baseUrl: { type: 'string', description: 'Base URL to test instead of the saved one; empty for the official endpoint' } }, ['provider']),
  controlTool('settings_set_api_key', 'set_api_key',
    'Save a provider\'s API key in the macOS Keychain, replacing any saved one. Keys are write-only: the result shows only the masked hint (first and last 4 characters) and whether a key was saved before. Applies from the next message.',
    { ...provider, key: { type: 'string', description: 'The API key' } }),
  controlTool('settings_delete_api_key', 'delete_api_key',
    'Delete a provider\'s API key from the Keychain. If the selected conversation used that provider, it switches to another provider that has a key. Returns the previous masked hint; applies from the next message.',
    provider),
  controlTool('settings_get_connectors', 'get_connectors',
    'Check and read the MCP connectors: whether the Fudehand MCP server is registered with Claude Code, Codex, and DeepSeek Harness (connected, disconnected, registered to another location or with a Node.js that no longer exists, or the Agent is not installed), and the Node.js the server runs on (found, too old, or missing, with what to install).'),
  controlTool('settings_set_connector', 'set_connector',
    'Connect or disconnect an MCP connector: register the Fudehand MCP server in that Agent\'s user-level configuration, or remove it. Connecting a connector registered to another location points it at this App instead. Needs Node.js (see settings_get_connectors). Returns the new and previous status and the command run or file changed; the Agent picks the change up in new sessions.',
    {
      connector: { type: 'string', enum: ['claude', 'codex', 'deepseek'], description: 'claude (Claude Code), codex (Codex), or deepseek (DeepSeek Harness)' },
      connected: { type: 'boolean', description: 'true to connect, false to disconnect' },
    }),
  ...styleTools,
]

/** Tool arguments that hold secrets: whoever shows or records a tool call masks these. */
export const secretArguments = { settings_set_api_key: ['key'] }

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
