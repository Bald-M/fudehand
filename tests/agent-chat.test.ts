import { afterEach, describe, expect, it } from 'vitest'
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { atlasWorkspace } from './helpers/atlas-workspace'

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

/** 启动 harness，返回发送消息与按需等待事件的方法。 */
async function startHarness(env: Record<string, string>) {
  const { root, dispose } = await atlasWorkspace()
  cleanup.push(dispose)
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
  it('多轮对话并通过工具列出作品', async () => {
    const model = await fakeModel([openaiTool('call_1', 'list_projects', {}), openaiText('共有 1 个作品：演示作品。'), openaiText('不客气。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const first = await chat.ask('列出作品')
    expect(first.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'done'])
    expect(first[0]).toMatchObject({ name: 'list_projects', args: {} })
    expect(first[1]).toMatchObject({ name: 'list_projects', ok: true })
    expect(first[1].text).toContain('演示作品')
    expect(first[2].text).toBe('共有 1 个作品：演示作品。')
    await chat.ask('谢谢')
    expect(model.requests[0].url).toBe('/chat/completions')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
    expect(model.requests[0].body.model).toBe('deepseek-chat')
    expect(model.requests[0].body.tools.map((tool: any) => tool.function.name)).toContain('add_frame')
    const third = model.requests[2].body.messages
    expect(third.map((message: any) => message.role)).toEqual(['system', 'user', 'assistant', 'tool', 'assistant', 'user'])
    expect(third[3]).toMatchObject({ role: 'tool', tool_call_id: 'call_1' })
  })

  it('add_frame 校验失败时把中文错误交给模型且不改文件', async () => {
    const model = await fakeModel([
      openaiTool('call_1', 'add_frame', { project: 'demo', frame: { id: 'home', title: '重复', platform: 'mobile', path: '/demo/x', width: 390, height: 844 } }),
      openaiText('画框 id 重复了。'),
    ])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const before = await readFile(join(chat.root, 'catalog.json'), 'utf8')
    const events = await chat.ask('给 demo 加一个 390×844 画框')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false })
    expect(events[1].text).toContain('画框 id 必须非空且唯一')
    expect(model.requests[1].body.messages.at(-1).content).toContain('画框 id 必须非空且唯一')
    expect(await readFile(join(chat.root, 'catalog.json'), 'utf8')).toBe(before)
  })

  it('画布工具在 App 未运行时返回中文错误', async () => {
    const model = await fakeModel([openaiTool('call_1', 'canvas_focus_frame', { frame: 'home' }), openaiText('App 没有运行。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const events = await chat.ask('聚焦首页')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false, text: '界面图鉴未运行' })
  })

  it('HTTP 错误、网络失败与未配置 key 显示中文错误', async () => {
    const model = await fakeModel([
      { status: 401, body: { error: { message: `Incorrect API key provided: ${KEY}` } } },
      { status: 429, body: { error: { message: 'rate limited' } } },
      { status: 402, body: { error: { message: 'Insufficient Balance' } } },
      { status: 500, body: { error: { message: 'boom' } } },
    ])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const messages = []
    for (let i = 0; i < 4; i++) messages.push((await chat.ask('你好')).find(event => event.type === 'error')?.message)
    expect(messages).toEqual(['API key 无效或无权限', '额度不足或请求过于频繁', '额度不足或请求过于频繁', '模型 API 报错（HTTP 500）：boom'])

    const offline = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: 'http://127.0.0.1:9', UI_ATLAS_API_KEY: KEY })
    expect((await offline.ask('你好')).find(event => event.type === 'error')?.message).toMatch(/^无法连接模型 API/)

    const missing = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl })
    expect((await missing.ask('你好')).find(event => event.type === 'error')?.message).toBe('尚未配置 API key')
  })

  it('停止后不再执行后续工具调用', async () => {
    const model = await fakeModel([{ ...openaiTool('call_1', 'set_project_enabled', { project: 'demo', enabled: false }), delayMs: 800 }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const before = await readFile(join(chat.root, 'catalog.json'), 'utf8')
    const from = chat.events.length
    chat.send({ type: 'user', text: '停用 demo' })
    await new Promise(resolve => setTimeout(resolve, 200))
    chat.send({ type: 'stop' })
    const done = await chat.until(event => event.type === 'done', from)
    expect(done.stopped).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 1000))
    expect(chat.events.slice(from).some(event => event.type === 'tool_call')).toBe(false)
    expect(await readFile(join(chat.root, 'catalog.json'), 'utf8')).toBe(before)
  })

  it('参数不是合法 JSON 时不执行工具', async () => {
    const malformed = { body: { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'set_project_enabled', arguments: '{"project":' } }] } }] } }
    const model = await fakeModel([malformed, openaiText('参数有误。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const before = await readFile(join(chat.root, 'catalog.json'), 'utf8')
    const events = await chat.ask('停用 demo')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false, text: '工具参数不是合法 JSON' })
    expect(await readFile(join(chat.root, 'catalog.json'), 'utf8')).toBe(before)
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
    const model = await fakeModel([{ ...openaiTool('call_1', 'list_projects', {}), delayMs: 600 }, openaiText('好的')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const from = chat.events.length
    chat.send({ type: 'user', text: '列出作品' })
    await new Promise(resolve => setTimeout(resolve, 150))
    chat.send({ type: 'stop' })
    await chat.until(event => event.type === 'done', from)
    await chat.ask('继续')
    expect(model.requests.at(-1)!.body.messages.map((message: any) => message.role)).toEqual(['system', 'user', 'user'])
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
  it('多轮对话并通过工具列出作品', async () => {
    const model = await fakeModel([responsesTool('call_1', 'list_projects', {}), responsesText('共有 1 个作品。'), responsesText('好的。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'openai', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const first = await chat.ask('列出作品')
    expect(first.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'done'])
    await chat.ask('谢谢')
    expect(model.requests[0].url).toBe('/responses')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
    expect(model.requests[0].body.model).toBe('gpt-5-codex')
    expect(typeof model.requests[0].body.instructions).toBe('string')
    expect(model.requests[0].body.tools[0]).toMatchObject({ type: 'function', name: 'list_projects' })
    expect(model.requests[2].body.input).toEqual([
      { role: 'user', content: '列出作品' },
      { type: 'function_call', call_id: 'call_1', name: 'list_projects', arguments: '{}' },
      { type: 'function_call_output', call_id: 'call_1', output: expect.stringContaining('演示作品') },
      { role: 'assistant', content: '共有 1 个作品。' },
      { role: 'user', content: '谢谢' },
    ])
  })
})

describe('Agent harness：Anthropic Messages API', () => {
  it('多轮对话并通过工具列出作品', async () => {
    const model = await fakeModel([anthropicTool('toolu_1', 'list_projects', {}), anthropicText('共有 1 个作品。'), anthropicText('好的。')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const first = await chat.ask('列出作品')
    expect(first.map(event => event.type)).toEqual(['assistant', 'tool_call', 'tool_result', 'assistant', 'done'])
    await chat.ask('谢谢')
    expect(model.requests[0].url).toBe('/v1/messages')
    expect(model.requests[0].headers['x-api-key']).toBe(KEY)
    expect(model.requests[0].headers['anthropic-version']).toBe('2023-06-01')
    expect(model.requests[0].body.model).toBe('claude-sonnet-5-5')
    expect(model.requests[0].body.tools.map((tool: any) => tool.name)).toContain('frame_snapshot')
    expect(typeof model.requests[0].body.system).toBe('string')
    const messages = model.requests[2].body.messages
    expect(messages.map((message: any) => message.role)).toEqual(['user', 'assistant', 'user', 'assistant', 'user'])
    expect(messages[1].content.at(-1)).toMatchObject({ type: 'tool_use', id: 'toolu_1', name: 'list_projects' })
    expect(messages[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'toolu_1' })
  })

  it('工具失败时标记 is_error，回复被截断时报错', async () => {
    const model = await fakeModel([
      anthropicTool('toolu_1', 'get_project', { project: 'nope' }), anthropicText('没有这个作品。'),
      { body: { content: [{ type: 'tool_use', id: 'toolu_2', name: 'list_projects', input: {} }], stop_reason: 'max_tokens' } },
    ])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    await chat.ask('看看 nope')
    expect(model.requests[1].body.messages[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'toolu_1', is_error: true })
    const truncated = await chat.ask('列出作品')
    expect(truncated.map(event => event.type)).toEqual(['error', 'done'])
    expect(truncated[0].message).toBe('模型回复因长度限制被截断，已停止本次回复')
  })

  it('HTTP 错误显示中文', async () => {
    const model = await fakeModel([{ status: 529, body: { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } } }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect((await chat.ask('你好')).find(event => event.type === 'error')?.message).toBe('模型 API 报错（HTTP 529）：Overloaded')
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

  it('错误显示中文，且 key 不出现在输出中', async () => {
    const model = await fakeModel([{ status: 401, body: { error: { message: `bad key ${KEY}` } } }, { status: 404, body: { error: { message: `no route for ${KEY}` } } }])
    const unauthorized = await listModels({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect(unauthorized.event).toEqual({ type: 'error', message: 'API key 无效或无权限' })
    const missing = await listModels({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect(missing.event.type).toBe('error')
    expect(missing.output).not.toContain(KEY)
    expect((await listModels({ UI_ATLAS_PROVIDER: 'deepseek' })).event).toEqual({ type: 'error', message: '尚未配置 API key' })
  })
})
