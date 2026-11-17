import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { createInterface } from 'node:readline'
import { callTool, tools } from './atlas-tools.mjs'
import { createProvider, listModels } from './agent-providers.mjs'

/**
 * App 内对话面板的 Agent harness。由 ui-atlas 按需启动，经 stdin/stdout 交换 JSON 行：
 *   输入：{type:'user',text} | {type:'stop'} | {type:'clear'}
 *   输出：{type:'assistant',text} | {type:'tool_call',id,name,args} | {type:'tool_result',id,name,ok,text}
 *        | {type:'error',message} | {type:'done',stopped}
 * 提供方、模型、baseUrl 与 API key 只经环境变量传入；stdin 关闭时退出。
 * 带 --list-models 时只输出一行 {type:'models',models,default} 或 {type:'error',message} 后退出。
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

/** 任何发给 App 的文本都去掉 API key，避免出现在界面或日志中。 */
function redact(text) {
  return apiKey ? String(text).split(apiKey).join('***') : String(text)
}

function emit(event) {
  process.stdout.write(JSON.stringify(event, (_key, value) => typeof value === 'string' ? redact(value) : value) + '\n')
}

if (values['list-models']) {
  try {
    if (!apiKey) throw new Error('尚未配置 API key')
    const settings = { provider: process.env.UI_ATLAS_PROVIDER || 'deepseek', baseUrl: process.env.UI_ATLAS_BASE_URL, apiKey }
    emit({ type: 'models', ...await listModels(settings, AbortSignal.timeout(15000)) })
  } catch (error) {
    emit({ type: 'error', message: error?.name === 'TimeoutError' ? '获取模型列表超时' : String(error?.message ?? error) })
  }
  // macOS 上管道写入是异步的，等输出写完再退出，避免模型很多时被截断。
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
  // 清空会话会替换 history；本轮回复始终写入开始时的那份历史。
  const log = history
  log.push({ role: 'user', text })
  try {
    if (providerError) throw new Error(providerError)
    if (!apiKey) throw new Error('尚未配置 API key')
    for (let round = 0; ; round++) {
      if (round === maximumRounds) throw new Error('工具调用轮数过多，已停止本次回复')
      const answer = await provider.turn(system, log, tools, signal)
      if (signal.aborted) break
      // 空回复两家接口都不接受写回历史，直接结束本轮。
      if (!answer.text && !answer.toolCalls.length) break
      log.push({ role: 'assistant', text: answer.text, toolCalls: answer.toolCalls })
      if (answer.text) emit({ type: 'assistant', text: answer.text })
      if (!answer.toolCalls.length) break
      for (const call of answer.toolCalls) {
        // 停止后不再执行任何后续工具调用，只为模型补上占位结果，保持历史完整。
        if (signal.aborted) { log.push({ role: 'tool', id: call.id, name: call.name, text: '使用者已停止本次回复，未执行。' }); continue }
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
  try { message = JSON.parse(line) } catch { return emit({ type: 'error', message: '收到无法解析的消息' }) }
  if (message.type === 'user' && typeof message.text === 'string') {
    if (current) return emit({ type: 'error', message: '上一条回复尚未结束' })
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
