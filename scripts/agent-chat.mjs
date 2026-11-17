import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { createInterface } from 'node:readline'
import { callTool, tools } from './atlas-tools.mjs'
import { createProvider, listModels } from './agent-providers.mjs'

/**
 * The Agent harness of the in-App chat panel. Started on demand by ui-atlas, exchanging JSON lines over stdin/stdout:
 *   Input:  {type:'user',text} | {type:'stop'} | {type:'clear'}
 *   Output: {type:'assistant',text} | {type:'tool_call',id,name,args} | {type:'tool_result',id,name,ok,text}
 *        | {type:'error',message} | {type:'done',stopped}
 * The provider, model, baseUrl, and API key are passed only through environment variables; exits when stdin closes.
 * With --list-models it only prints one line, {type:'models',models,default} or {type:'error',message}, then exits.
 */

const { values } = parseArgs({ options: { root: { type: 'string' }, 'list-models': { type: 'boolean' } } })
const ctx = { root: values.root ? resolve(values.root) : fileURLToPath(new URL('../', import.meta.url)) }
const apiKey = process.env.UI_ATLAS_API_KEY ?? ''
const maximumRounds = 16

const system = [
  'You are the design assistant built into ui-atlas. ui-atlas is a native design tool: the canvas shows a design document made of layers, and you and the user edit the same document.',
  'First use design_get_state or design_get_document to learn the current state, then make changes with design_create_node, design_update_node, design_delete_nodes, and design_move_node; the canvas updates immediately after each change.',
  'When building a UI, prefer frames with auto layout (layout), and create a whole group of layers with children in a single design_create_node call; mobile frames are usually 390×844.',
  'After making changes, take a design_snapshot to check the result, and adjust if something is off. Undo with design_undo; save with design_save_document.',
  'Reply in the same language as the user\'s latest message, and briefly explain what you did.',
].join('\n')

/** Strips the API key from any text sent to the App, so it never appears in the UI or logs. */
function redact(text) {
  return apiKey ? String(text).split(apiKey).join('***') : String(text)
}

function emit(event) {
  process.stdout.write(JSON.stringify(event, (_key, value) => typeof value === 'string' ? redact(value) : value) + '\n')
}

if (values['list-models']) {
  try {
    if (!apiKey) throw new Error('No API key configured')
    const settings = { provider: process.env.UI_ATLAS_PROVIDER || 'deepseek', baseUrl: process.env.UI_ATLAS_BASE_URL, apiKey }
    emit({ type: 'models', ...await listModels(settings, AbortSignal.timeout(15000)) })
  } catch (error) {
    emit({ type: 'error', message: error?.name === 'TimeoutError' ? 'Timed out fetching the model list' : String(error?.message ?? error) })
  }
  // Pipe writes are asynchronous on macOS; wait for the output to be written before exiting, so it is not truncated when there are many models.
  await new Promise(resolve => process.stdout.write('', resolve))
  process.exit(0)
}

let provider = null
let providerError = null
try { provider = createProvider({ provider: process.env.UI_ATLAS_PROVIDER || 'deepseek', model: process.env.UI_ATLAS_MODEL, baseUrl: process.env.UI_ATLAS_BASE_URL, apiKey }) }
catch (error) { providerError = error.message }

let history = []
let current = null

function toolText(result) {
  return result.content.filter(item => item.type === 'text').map(item => item.text).join('\n')
}

async function reply(text, controller) {
  const { signal } = controller
  // Clearing the conversation replaces history; this turn's reply always goes into the history it started with.
  const log = history
  log.push({ role: 'user', text })
  try {
    if (providerError) throw new Error(providerError)
    if (!apiKey) throw new Error('No API key configured')
    for (let round = 0; ; round++) {
      if (round === maximumRounds) throw new Error('Too many tool-call rounds; stopped this reply')
      const answer = await provider.turn(system, log, tools, signal)
      if (signal.aborted) break
      // Neither API accepts an empty reply written back into the history, so end this turn right away.
      if (!answer.text && !answer.toolCalls.length) break
      log.push({ role: 'assistant', text: answer.text, toolCalls: answer.toolCalls, blocks: answer.blocks })
      if (answer.text) emit({ type: 'assistant', text: answer.text })
      if (!answer.toolCalls.length) break
      for (const call of answer.toolCalls) {
        // After a stop, no further tool calls are executed; placeholder results are only filled in for the model to keep the history complete.
        if (signal.aborted) { log.push({ role: 'tool', id: call.id, name: call.name, text: 'The user stopped this reply; not executed.' }); continue }
        emit({ type: 'tool_call', id: call.id, name: call.name, args: call.args })
        const result = call.error ? { isError: true, content: [{ type: 'text', text: call.error }] } : await callTool(call.name, call.args, ctx)
        const output = toolText(result)
        log.push({ role: 'tool', id: call.id, name: call.name, text: output, isError: Boolean(result.isError) })
        emit({ type: 'tool_result', id: call.id, name: call.name, ok: !result.isError, text: output.slice(0, 4000) })
      }
      if (signal.aborted) break
    }
  } catch (error) {
    if (!signal.aborted) emit({ type: 'error', message: error instanceof Error ? error.message : String(error) })
  } finally {
    current = null
    emit({ type: 'done', stopped: signal.aborted })
  }
}

const input = createInterface({ input: process.stdin })
input.on('line', line => {
  let message
  try { message = JSON.parse(line) } catch { return emit({ type: 'error', message: 'Received an unparseable message' }) }
  if (message.type === 'user' && typeof message.text === 'string') {
    if (current) return emit({ type: 'error', message: 'The previous reply has not finished yet' })
    current = new AbortController()
    void reply(message.text, current)
  } else if (message.type === 'stop') {
    current?.abort()
  } else if (message.type === 'clear') {
    current?.abort()
    history = []
  }
})
input.on('close', () => {
  current?.abort()
  process.exit(0)
})
