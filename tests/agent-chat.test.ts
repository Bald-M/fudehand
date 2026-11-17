import { afterEach, describe, expect, it } from 'vitest'
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fakeApp, type ControlRequest } from './helpers/fake-app'

const harness = fileURLToPath(new URL('../scripts/agent-chat.mjs', import.meta.url))
const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

const KEY = 'sk-test-secret-0123456789'

type Reply = { status?: number, body: unknown, delayMs?: number }
type Captured = { url: string, headers: IncomingMessage['headers'], body: any }

/** 本地假模型服务：按顺序返回预设响应，并记录收到的请求。 */
async function fakeModel(replies: Reply[]) {
  const requests: Captured[] = []
  const server = createServer(async (request: IncomingMessage, response: ServerResponse) => {
    let raw = ''
    for await (const chunk of request) raw += chunk
    requests.push({ url: request.url ?? '', headers: request.headers, body: JSON.parse(raw || '{}') })
    const reply = replies.shift() ?? { status: 500, body: { error: { message: '没有更多预设响应' } } }
    if (reply.delayMs) await new Promise(resolve => setTimeout(resolve, reply.delayMs))
    if (response.destroyed) return
    response.writeHead(reply.status ?? 200, { 'content-type': 'application/json' })
    response.end(JSON.stringify(reply.body))
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('未获得测试端口')
  cleanup.push(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)) })
  return { requests, baseUrl: `http://127.0.0.1:${address.port}` }
}

type Event = { type: string, [key: string]: any }

const STATE = { file: null, dirty: false, selection: [], layers: [{ id: 'home', type: 'frame', name: '演示页面' }] }

/** 启动假 App：get_state 返回演示文档，其余命令交给 respond（默认报错）。 */
async function startApp(respond: (request: ControlRequest) => object = request => ({ ok: false, error: `未处理的命令：${request.command}` })) {
  const app = await fakeApp(request => request.command === 'get_state' ? { ok: true, result: STATE } : respond(request))
  cleanup.push(app.close)
  return app
}

/** 启动 harness，返回发送消息与按需等待事件的方法。 */
async function startHarness(env: Record<string, string>) {
  const root = await mkdtemp(join(tmpdir(), 'uia-chat-'))
  cleanup.push(() => rm(root, { recursive: true, force: true }))
  const child: ChildProcess = spawn(process.execPath, [harness, '--root', root], {
    env: { PATH: process.env.PATH ?? '', UI_ATLAS_CONTROL_SOCKET: join(root, 'missing.sock'), ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events: Event[] = []
  let output = ''
  let errors = ''
  const waiters: (() => void)[] = []
  child.stdout!.setEncoding('utf8')
  child.stdout!.on('data', chunk => {
    output += chunk
    let index
    while ((index = output.indexOf('\n')) >= 0) {
      events.push(JSON.parse(output.slice(0, index)))
      output = output.slice(index + 1)
      waiters.splice(0).forEach(wake => wake())
    }
  })
  child.stderr!.setEncoding('utf8')
  child.stderr!.on('data', chunk => { errors += chunk })
  const exited = new Promise<number | null>(resolve => child.once('exit', code => resolve(code)))
  cleanup.push(async () => { child.kill(); await exited })
  async function until(predicate: (event: Event) => boolean, from = 0) {
    const deadline = Date.now() + 10000
    for (;;) {
      const found = events.slice(from).find(predicate)
      if (found) return found
      if (Date.now() > deadline) throw new Error(`等待事件超时：${JSON.stringify(events)}\n${errors}`)
      await new Promise<void>(resolve => { waiters.push(resolve); setTimeout(resolve, 200) })
    }
  }
  return {
    root, events, exited, child,
    stderr: () => errors,
    send: (message: object) => child.stdin!.write(JSON.stringify(message) + '\n'),
    /** 发送一条用户消息并等待本轮结束，返回本轮事件。 */
    async ask(text: string) {
      const from = events.length
      child.stdin!.write(JSON.stringify({ type: 'user', text }) + '\n')
      await until(event => event.type === 'done', from)
      return events.slice(from)
    },
    until,
  }
}

const openaiText = (content: string) => ({ body: { choices: [{ message: { role: 'assistant', content } }] } })
const openaiTool = (id: string, name: string, args: object) => ({ body: { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id, type: 'function', function: { name, arguments: JSON.stringify(args) } }] } }] } })
const responsesText = (text: string) => ({ body: { status: 'completed', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] }] } })
const responsesTool = (callId: string, name: string, args: object) => ({ body: { status: 'completed', output: [{ type: 'function_call', id: `fc_${callId}`, call_id: callId, name, arguments: JSON.stringify(args) }] } })
const anthropicText = (text: string) => ({ body: { content: [{ type: 'text', text }], stop_reason: 'end_turn' } })
const anthropicTool = (id: string, name: string, input: object) => ({ body: { content: [{ type: 'text', text: '我来查一下。' }, { type: 'tool_use', id, name, input }], stop_reason: 'tool_use' } })

describe('Agent harness：OpenAI 兼容接口（DeepSeek / OpenAI）', () => {
  it('多轮对话并通过工具读取设计文档', async () => {
    const app = await startApp()
    const model = await fakeModel([openaiTool('call_1', 'design_get_state', {}), openaiText('文档里有 1 个画框：演示页面。'), openaiText('不客气。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const first = await chat.ask('看看文档')
    expect(first.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'done'])
    expect(first[0]).toMatchObject({ name: 'design_get_state', args: {} })
    expect(first[1]).toMatchObject({ name: 'design_get_state', ok: true })
    expect(first[1].text).toContain('演示页面')
    expect(first[2].text).toBe('文档里有 1 个画框：演示页面。')
    expect(app.received.map(request => request.command)).toEqual(['get_state'])
    await chat.ask('谢谢')
    expect(model.requests[0].url).toBe('/chat/completions')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
    expect(model.requests[0].body.model).toBe('deepseek-chat')
    expect(model.requests[0].body.tools.map((tool: any) => tool.function.name)).toContain('design_create_node')
    const third = model.requests[2].body.messages
    expect(third.map((message: any) => message.role)).toEqual(['system', 'user', 'assistant', 'tool', 'assistant', 'user'])
    expect(third[3]).toMatchObject({ role: 'tool', tool_call_id: 'call_1' })
  })

  it('hands the App error to the model when an edit is rejected, sending only that one command', async () => {
    const app = await startApp(() => ({ ok: false, error: 'Layer not found: nope' }))
    const model = await fakeModel([
      openaiTool('call_1', 'design_update_node', { id: 'nope', changes: { name: '标题' } }),
      openaiText('没有这个图层。'),
    ])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('把 nope 改名为标题')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false })
    expect(events[1].text).toContain('Layer not found: nope')
    expect(model.requests[1].body.messages.at(-1).content).toContain('Layer not found: nope')
    expect(app.received).toEqual([{ id: expect.anything(), command: 'update_node', args: { id: 'nope', changes: { name: '标题' } } }])
  })

  it('canvas tools return an English error when the App is not running', async () => {
    const model = await fakeModel([openaiTool('call_1', 'canvas_focus_node', { id: 'home' }), openaiText('App 没有运行。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const events = await chat.ask('聚焦首页')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false, text: 'ui-atlas is not running' })
  })

  it('HTTP errors, network failures and a missing key show English errors', async () => {
    const model = await fakeModel([
      { status: 401, body: { error: { message: `Incorrect API key provided: ${KEY}` } } },
      { status: 429, body: { error: { message: 'rate limited' } } },
      { status: 402, body: { error: { message: 'Insufficient Balance' } } },
      { status: 500, body: { error: { message: 'boom' } } },
    ])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const messages = []
    for (let i = 0; i < 4; i++) messages.push((await chat.ask('你好')).find(event => event.type === 'error')?.message)
    expect(messages).toEqual(['Invalid API key or insufficient permissions', 'Quota exceeded or too many requests', 'Quota exceeded or too many requests', 'Model API error (HTTP 500): boom'])

    const offline = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: 'http://127.0.0.1:9', UI_ATLAS_API_KEY: KEY })
    expect((await offline.ask('你好')).find(event => event.type === 'error')?.message).toMatch(/^Could not connect to the model API/)

    const missing = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl })
    expect((await missing.ask('你好')).find(event => event.type === 'error')?.message).toBe('No API key configured')
  })

  it('停止后不再执行后续工具调用', async () => {
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const model = await fakeModel([{ ...openaiTool('call_1', 'design_delete_nodes', { ids: ['home'] }), delayMs: 800 }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const from = chat.events.length
    chat.send({ type: 'user', text: '删除首页' })
    await new Promise(resolve => setTimeout(resolve, 200))
    chat.send({ type: 'stop' })
    const done = await chat.until(event => event.type === 'done', from)
    expect(done.stopped).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 1000))
    expect(chat.events.slice(from).some(event => event.type === 'tool_call')).toBe(false)
    expect(app.received).toEqual([])
  })

  it('参数不是合法 JSON 时不执行工具', async () => {
    const malformed = { body: { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'design_delete_nodes', arguments: '{"ids":' } }] } }] } }
    const model = await fakeModel([malformed, openaiText('参数有误。')])
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('删除首页')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false, text: 'Tool arguments are not valid JSON' })
    expect(app.received).toEqual([])
  })

  it('空回复不写入历史，清空后从新会话开始', async () => {
    const model = await fakeModel([{ body: { choices: [{ message: { role: 'assistant', content: null } }] } }, openaiText('第二次'), openaiText('清空后')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    await chat.ask('一')
    await chat.ask('二')
    expect(model.requests[1].body.messages.map((message: any) => message.role)).toEqual(['system', 'user', 'user'])
    chat.send({ type: 'clear' })
    await chat.ask('三')
    expect(model.requests[2].body.messages.map((message: any) => message.content)).toEqual([expect.any(String), '三'])
  })

  it('停止后下一轮请求的历史格式有效', async () => {
    const app = await startApp()
    const model = await fakeModel([{ ...openaiTool('call_1', 'design_get_state', {}), delayMs: 600 }, openaiText('好的')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const from = chat.events.length
    chat.send({ type: 'user', text: '看看文档' })
    await new Promise(resolve => setTimeout(resolve, 150))
    chat.send({ type: 'stop' })
    await chat.until(event => event.type === 'done', from)
    await chat.ask('继续')
    expect(model.requests.at(-1)!.body.messages.map((message: any) => message.role)).toEqual(['system', 'user', 'user'])
  })

  it('工具调用超过 16 轮时停止本次回复', async () => {
    const app = await startApp()
    const model = await fakeModel(Array.from({ length: 17 }, (_, index) => openaiTool(`call_${index}`, 'design_get_state', {})))
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('一直查')
    expect(events.at(-2)).toEqual({ type: 'error', message: 'Too many tool-call rounds; stopped this reply' })
    expect(model.requests).toHaveLength(16)
    expect(app.received).toHaveLength(16)
  })

  it('stdin 关闭后进程退出，key 不出现在输出中', async () => {
    const model = await fakeModel([{ status: 401, body: { error: { message: `bad key ${KEY}` } } }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    await chat.ask('你好')
    chat.child.stdin!.end()
    expect(await chat.exited).toBe(0)
    expect(JSON.stringify(chat.events) + chat.stderr()).not.toContain(KEY)
  })
})

describe('Agent harness：OpenAI Responses API（Codex 系列）', () => {
  it('多轮对话并通过工具读取设计文档', async () => {
    const app = await startApp()
    const model = await fakeModel([responsesTool('call_1', 'design_get_state', {}), responsesText('有 1 个画框。'), responsesText('好的。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'openai', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const first = await chat.ask('看看文档')
    expect(first.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'done'])
    await chat.ask('谢谢')
    expect(model.requests[0].url).toBe('/responses')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
    expect(model.requests[0].body.model).toBe('gpt-5-codex')
    expect(typeof model.requests[0].body.instructions).toBe('string')
    expect(model.requests[0].body.tools[0]).toMatchObject({ type: 'function', name: 'design_get_state' })
    expect(model.requests[2].body.input).toEqual([
      { role: 'user', content: '看看文档' },
      { type: 'function_call', call_id: 'call_1', name: 'design_get_state', arguments: '{}' },
      { type: 'function_call_output', call_id: 'call_1', output: expect.stringContaining('演示页面') },
      { role: 'assistant', content: '有 1 个画框。' },
      { role: 'user', content: '谢谢' },
    ])
  })
})

describe('Agent harness：Anthropic Messages API', () => {
  it('多轮对话并通过工具读取设计文档', async () => {
    const app = await startApp()
    const model = await fakeModel([anthropicTool('toolu_1', 'design_get_state', {}), anthropicText('有 1 个画框。'), anthropicText('好的。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const first = await chat.ask('看看文档')
    expect(first.map(event => event.type)).toEqual(['assistant', 'tool_call', 'tool_result', 'assistant', 'done'])
    await chat.ask('谢谢')
    expect(model.requests[0].url).toBe('/v1/messages')
    expect(model.requests[0].headers['x-api-key']).toBe(KEY)
    expect(model.requests[0].headers['anthropic-version']).toBe('2023-06-01')
    expect(model.requests[0].body.model).toBe('claude-sonnet-5-5')
    expect(model.requests[0].body.tools.map((tool: any) => tool.name)).toContain('design_snapshot')
    expect(typeof model.requests[0].body.system).toBe('string')
    const messages = model.requests[2].body.messages
    expect(messages.map((message: any) => message.role)).toEqual(['user', 'assistant', 'user', 'assistant', 'user'])
    expect(messages[1].content.at(-1)).toMatchObject({ type: 'tool_use', id: 'toolu_1', name: 'design_get_state' })
    expect(messages[2].content[0].content).toContain('演示页面')
    expect(messages[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'toolu_1' })
  })

  it('工具失败时标记 is_error，回复被截断时报错', async () => {
    const model = await fakeModel([
      anthropicTool('toolu_1', 'design_get_node', { id: 'nope' }), anthropicText('没有这个图层。'),
      { body: { content: [{ type: 'tool_use', id: 'toolu_2', name: 'design_get_state', input: {} }], stop_reason: 'max_tokens' } },
    ])
    const app = await startApp(() => ({ ok: false, error: 'Layer not found: nope' }))
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    await chat.ask('看看 nope')
    expect(model.requests[1].body.messages[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'toolu_1', is_error: true })
    const truncated = await chat.ask('看看文档')
    expect(truncated.map(event => event.type)).toEqual(['error', 'done'])
    expect(truncated[0].message).toBe('The model reply was cut off by the length limit; stopped this reply')
    expect(app.received.map(request => request.command)).toEqual(['get_node'])
  })

  it('HTTP errors are shown in English', async () => {
    const model = await fakeModel([{ status: 529, body: { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } } }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect((await chat.ask('你好')).find(event => event.type === 'error')?.message).toBe('Model API error (HTTP 529): Overloaded')
  })
})

/** 以 --list-models 运行 harness，返回唯一一行输出和退出码。 */
async function listModels(env: Record<string, string>) {
  const child = spawn(process.execPath, [harness, '--list-models'], { env: { PATH: process.env.PATH ?? '', ...env }, stdio: ['ignore', 'pipe', 'pipe'] })
  let output = ''
  child.stdout!.setEncoding('utf8')
  child.stdout!.on('data', chunk => { output += chunk })
  const code = await new Promise<number | null>(resolve => child.once('exit', resolve))
  return { code, output, event: JSON.parse(output.trim()) }
}

describe('Agent harness：列出可用模型', () => {
  it('OpenAI 兼容接口读取 /models 并带上默认模型', async () => {
    const model = await fakeModel([{ body: { object: 'list', data: [{ id: 'deepseek-chat' }, { id: 'deepseek-reasoner' }, { id: 'deepseek-chat' }] } }])
    const result = await listModels({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: `${model.baseUrl}/`, UI_ATLAS_API_KEY: KEY })
    expect(result.code).toBe(0)
    expect(result.event).toEqual({ type: 'models', models: ['deepseek-chat', 'deepseek-reasoner'], default: 'deepseek-chat' })
    expect(model.requests[0].url).toBe('/models')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
  })

  it('OpenAI Responses 提供方同样读取 /models', async () => {
    const model = await fakeModel([{ body: { data: [{ id: 'gpt-5-codex' }] } }])
    const result = await listModels({ UI_ATLAS_PROVIDER: 'openai', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect(result.event).toEqual({ type: 'models', models: ['gpt-5-codex'], default: 'gpt-5-codex' })
    expect(model.requests[0].url).toBe('/models')
  })

  it('Anthropic 读取 /v1/models 并使用自己的鉴权头', async () => {
    const model = await fakeModel([{ body: { data: [{ id: 'claude-opus-5-5', type: 'model' }, { id: 'claude-sonnet-5-5', type: 'model' }], has_more: false } }])
    const result = await listModels({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect(result.event).toEqual({ type: 'models', models: ['claude-opus-5-5', 'claude-sonnet-5-5'], default: 'claude-sonnet-5-5' })
    expect(model.requests[0].url).toBe('/v1/models?limit=1000')
    expect(model.requests[0].headers['x-api-key']).toBe(KEY)
    expect(model.requests[0].headers['anthropic-version']).toBe('2023-06-01')
  })

  it('errors are shown in English and the key never appears in the output', async () => {
    const model = await fakeModel([{ status: 401, body: { error: { message: `bad key ${KEY}` } } }, { status: 404, body: { error: { message: `no route for ${KEY}` } } }])
    const unauthorized = await listModels({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect(unauthorized.event).toEqual({ type: 'error', message: 'Invalid API key or insufficient permissions' })
    const missing = await listModels({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect(missing.event.type).toBe('error')
    expect(missing.output).not.toContain(KEY)
    expect((await listModels({ UI_ATLAS_PROVIDER: 'deepseek' })).event).toEqual({ type: 'error', message: 'No API key configured' })
  })
})
