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
  '你是 ui-atlas 内置的设计助手。ui-atlas 是原生设计工具：画布上是由图层组成的设计文档，你和使用者编辑同一份文档。',
  '先用 design_get_state 或 design_get_document 了解现状，再用 design_create_node、design_update_node、design_delete_nodes、design_move_node 修改；每次修改画布立即更新。',
  '搭建界面时优先用带自动布局（layout）的画框，在一次 design_create_node 中用 children 创建整组图层；移动端画框通常为 390×844。',
  '修改后用 design_snapshot 截图核对效果，有问题再调整。撤销用 design_undo；保存用 design_save_document。',
  '回答使用简体中文，简洁说明做了什么。',
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
    if (!apiKey) throw new Error('No API key configured')
    const settings = { provider: process.env.UI_ATLAS_PROVIDER || 'deepseek', baseUrl: process.env.UI_ATLAS_BASE_URL, apiKey }
    emit({ type: 'models', ...await listModels(settings, AbortSignal.timeout(15000)) })
  } catch (error) {
    emit({ type: 'error', message: error?.name === 'TimeoutError' ? 'Timed out fetching the model list' : String(error?.message ?? error) })
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
    if (!apiKey) throw new Error('No API key configured')
    for (let round = 0; ; round++) {
      if (round === maximumRounds) throw new Error('Too many tool-call rounds; stopped this reply')
      const answer = await provider.turn(system, log, tools, signal)
      if (signal.aborted) break
      // 空回复两家接口都不接受写回历史，直接结束本轮。
      if (!answer.text && !answer.toolCalls.length) break
      log.push({ role: 'assistant', text: answer.text, toolCalls: answer.toolCalls })
      if (answer.text) emit({ type: 'assistant', text: answer.text })
      if (!answer.toolCalls.length) break
      for (const call of answer.toolCalls) {
        // 停止后不再执行任何后续工具调用，只为模型补上占位结果，保持历史完整。
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
