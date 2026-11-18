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

/** A local fake model service: returns the preset responses in order and records the requests it receives. */
async function fakeModel(replies: Reply[]) {
  const requests: Captured[] = []
  const server = createServer(async (request: IncomingMessage, response: ServerResponse) => {
    let raw = ''
    for await (const chunk of request) raw += chunk
    requests.push({ url: request.url ?? '', headers: request.headers, body: JSON.parse(raw || '{}') })
    const reply = replies.shift() ?? { status: 500, body: { error: { message: 'No more preset responses' } } }
    if (reply.delayMs) await new Promise(resolve => setTimeout(resolve, reply.delayMs))
    if (response.destroyed) return
    response.writeHead(reply.status ?? 200, { 'content-type': 'application/json' })
    response.end(JSON.stringify(reply.body))
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Could not get a test port')
  cleanup.push(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)) })
  return { requests, baseUrl: `http://127.0.0.1:${address.port}` }
}

type Event = { type: string, [key: string]: any }

const STATE = { file: null, dirty: false, selection: [], layers: [{ id: 'home', type: 'frame', name: 'Demo page' }] }

/** Starts a fake App: get_state returns the demo document, and other commands go to respond (an error by default). */
async function startApp(respond: (request: ControlRequest) => object = request => ({ ok: false, error: `Unhandled command: ${request.command}` })) {
  const app = await fakeApp(request => request.command === 'get_state' ? { ok: true, result: STATE } : respond(request))
  cleanup.push(app.close)
  return app
}

/** Starts the harness, returning methods to send messages and to wait for events on demand. */
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
      if (Date.now() > deadline) throw new Error(`Timed out waiting for events: ${JSON.stringify(events)}\n${errors}`)
      await new Promise<void>(resolve => { waiters.push(resolve); setTimeout(resolve, 200) })
    }
  }
  return {
    root, events, exited, child,
    stderr: () => errors,
    send: (message: object) => child.stdin!.write(JSON.stringify(message) + '\n'),
    /** Sends one user message and waits for the turn to end, returning the turn's events. */
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
const anthropicTool = (id: string, name: string, input: object) => ({ body: { content: [{ type: 'text', text: 'Let me check.' }, { type: 'tool_use', id, name, input }], stop_reason: 'tool_use' } })

describe('Agent harness: OpenAI-compatible API (DeepSeek / OpenAI)', () => {
  it('holds a multi-turn conversation and reads the design document through tools', async () => {
    const app = await startApp()
    const model = await fakeModel([openaiTool('call_1', 'design_get_state', {}), openaiText('The document has 1 frame: Demo page.'), openaiText('You are welcome.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const first = await chat.ask('Look at the document')
    expect(first.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'done'])
    expect(first[0]).toMatchObject({ name: 'design_get_state', args: {} })
    expect(first[1]).toMatchObject({ name: 'design_get_state', ok: true })
    expect(first[1].text).toContain('Demo page')
    expect(first[2].text).toBe('The document has 1 frame: Demo page.')
    expect(app.received.map(request => request.command)).toEqual(['get_state'])
    await chat.ask('Thanks')
    expect(model.requests[0].url).toBe('/chat/completions')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
    expect(model.requests[0].body.model).toBe('deepseek-chat')
    expect(model.requests[0].body.tools.map((tool: any) => tool.function.name)).toContain('design_create_node')
    const third = model.requests[2].body.messages
    expect(third.map((message: any) => message.role)).toEqual(['system', 'user', 'assistant', 'tool', 'assistant', 'user'])
    expect(third[3]).toMatchObject({ role: 'tool', tool_call_id: 'call_1' })
    const system = third[0].content
    // The Chinese range is deliberate: it asserts the system prompt contains no Chinese.
    expect(system).not.toMatch(/[一-鿿]/)
    expect(system).toMatch(/same language as the user/)
  })

  it('hands the App error to the model when an edit is rejected, sending only that one command', async () => {
    const app = await startApp(() => ({ ok: false, error: 'Layer not found: nope' }))
    const model = await fakeModel([
      openaiTool('call_1', 'design_update_node', { id: 'nope', changes: { name: 'Title' } }),
      openaiText('There is no such layer.'),
    ])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Rename nope to Title')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false })
    expect(events[1].text).toContain('Layer not found: nope')
    expect(model.requests[1].body.messages.at(-1).content).toContain('Layer not found: nope')
    expect(app.received).toEqual([{ id: expect.anything(), command: 'update_node', args: { id: 'nope', changes: { name: 'Title' } } }])
  })

  it('canvas tools return an English error when the App is not running', async () => {
    const model = await fakeModel([openaiTool('call_1', 'canvas_focus_node', { id: 'home' }), openaiText('The App is not running.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const events = await chat.ask('Focus the home page')
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
    for (let i = 0; i < 4; i++) messages.push((await chat.ask('Hello')).find(event => event.type === 'error')?.message)
    expect(messages).toEqual(['Invalid API key or insufficient permissions', 'Quota exceeded or too many requests', 'Quota exceeded or too many requests', 'Model API error (HTTP 500): boom'])

    const offline = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: 'http://127.0.0.1:9', UI_ATLAS_API_KEY: KEY })
    expect((await offline.ask('Hello')).find(event => event.type === 'error')?.message).toMatch(/^Could not connect to the model API/)

    const missing = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl })
    expect((await missing.ask('Hello')).find(event => event.type === 'error')?.message).toBe('No API key configured')
  })

  it('executes no further tool calls after a stop', async () => {
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const model = await fakeModel([{ ...openaiTool('call_1', 'design_delete_nodes', { ids: ['home'] }), delayMs: 800 }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const from = chat.events.length
    chat.send({ type: 'user', text: 'Delete the home page' })
    await new Promise(resolve => setTimeout(resolve, 200))
    chat.send({ type: 'stop' })
    const done = await chat.until(event => event.type === 'done', from)
    expect(done.stopped).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 1000))
    expect(chat.events.slice(from).some(event => event.type === 'tool_call')).toBe(false)
    expect(app.received).toEqual([])
  })

  it('does not execute a tool whose arguments are not valid JSON', async () => {
    const malformed = { body: { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'design_delete_nodes', arguments: '{"ids":' } }] } }] } }
    const model = await fakeModel([malformed, openaiText('The arguments are wrong.')])
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Delete the home page')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false, text: 'Tool arguments are not valid JSON' })
    expect(app.received).toEqual([])
  })

  it('keeps an empty reply out of the history and starts a new conversation after clearing', async () => {
    const model = await fakeModel([{ body: { choices: [{ message: { role: 'assistant', content: null } }] } }, openaiText('Second'), openaiText('After clearing')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    await chat.ask('one')
    await chat.ask('two')
    expect(model.requests[1].body.messages.map((message: any) => message.role)).toEqual(['system', 'user', 'user'])
    chat.send({ type: 'clear' })
    await chat.ask('three')
    expect(model.requests[2].body.messages.map((message: any) => message.content)).toEqual([expect.any(String), 'three'])
  })

  it('sends a validly formatted history in the next request after a stop', async () => {
    const app = await startApp()
    const model = await fakeModel([{ ...openaiTool('call_1', 'design_get_state', {}), delayMs: 600 }, openaiText('OK')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const from = chat.events.length
    chat.send({ type: 'user', text: 'Look at the document' })
    await new Promise(resolve => setTimeout(resolve, 150))
    chat.send({ type: 'stop' })
    await chat.until(event => event.type === 'done', from)
    await chat.ask('Continue')
    expect(model.requests.at(-1)!.body.messages.map((message: any) => message.role)).toEqual(['system', 'user', 'user'])
  })

  it('stops the reply when tool calls exceed 16 rounds', async () => {
    const app = await startApp()
    const model = await fakeModel(Array.from({ length: 17 }, (_, index) => openaiTool(`call_${index}`, 'design_get_state', {})))
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Keep checking')
    expect(events.at(-2)).toEqual({ type: 'error', message: 'Too many tool-call rounds; stopped this reply' })
    expect(model.requests).toHaveLength(16)
    expect(app.received).toHaveLength(16)
  })

  it('exits after stdin closes and keeps the key out of the output', async () => {
    const model = await fakeModel([{ status: 401, body: { error: { message: `bad key ${KEY}` } } }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    await chat.ask('Hello')
    chat.child.stdin!.end()
    expect(await chat.exited).toBe(0)
    expect(JSON.stringify(chat.events) + chat.stderr()).not.toContain(KEY)
  })
})

describe('Agent harness: OpenAI Responses API (Codex series)', () => {
  it('holds a multi-turn conversation and reads the design document through tools', async () => {
    const app = await startApp()
    const model = await fakeModel([responsesTool('call_1', 'design_get_state', {}), responsesText('There is 1 frame.'), responsesText('OK.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'openai', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const first = await chat.ask('Look at the document')
    expect(first.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'done'])
    await chat.ask('Thanks')
    expect(model.requests[0].url).toBe('/responses')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
    expect(model.requests[0].body.model).toBe('gpt-5.3-codex')
    expect(typeof model.requests[0].body.instructions).toBe('string')
    expect(model.requests[0].body.tools[0]).toMatchObject({ type: 'function', name: 'design_get_state' })
    // The tool schemas have optional fields and free-form objects, which strict mode rejects.
    expect(model.requests[0].body.tools.every((tool: any) => tool.strict === false)).toBe(true)
    expect(model.requests[2].body.input).toEqual([
      { role: 'user', content: 'Look at the document' },
      { type: 'function_call', call_id: 'call_1', name: 'design_get_state', arguments: '{}' },
      { type: 'function_call_output', call_id: 'call_1', output: expect.stringContaining('Demo page') },
      { role: 'assistant', content: 'There is 1 frame.' },
      { role: 'user', content: 'Thanks' },
    ])
  })
})

describe('Agent harness: Anthropic Messages API', () => {
  it('holds a multi-turn conversation and reads the design document through tools', async () => {
    const app = await startApp()
    const model = await fakeModel([anthropicTool('toolu_1', 'design_get_state', {}), anthropicText('There is 1 frame.'), anthropicText('OK.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const first = await chat.ask('Look at the document')
    expect(first.map(event => event.type)).toEqual(['assistant', 'tool_call', 'tool_result', 'assistant', 'done'])
    await chat.ask('Thanks')
    expect(model.requests[0].url).toBe('/v1/messages')
    expect(model.requests[0].headers['x-api-key']).toBe(KEY)
    expect(model.requests[0].headers['anthropic-version']).toBe('2023-06-01')
    expect(model.requests[0].body.model).toBe('claude-sonnet-5-5')
    expect(model.requests[0].body.tools.map((tool: any) => tool.name)).toContain('design_snapshot')
    expect(typeof model.requests[0].body.system).toBe('string')
    expect(model.requests[0].body.max_tokens).toBe(16000)
    const messages = model.requests[2].body.messages
    expect(messages.map((message: any) => message.role)).toEqual(['user', 'assistant', 'user', 'assistant', 'user'])
    expect(messages[1].content.at(-1)).toMatchObject({ type: 'tool_use', id: 'toolu_1', name: 'design_get_state' })
    expect(messages[2].content[0].content).toContain('Demo page')
    expect(messages[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'toolu_1' })
  })

  it('marks is_error when a tool fails and reports an error when the reply is truncated', async () => {
    const model = await fakeModel([
      anthropicTool('toolu_1', 'design_get_node', { id: 'nope' }), anthropicText('There is no such layer.'),
      { body: { content: [{ type: 'tool_use', id: 'toolu_2', name: 'design_get_state', input: {} }], stop_reason: 'max_tokens' } },
    ])
    const app = await startApp(() => ({ ok: false, error: 'Layer not found: nope' }))
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    await chat.ask('Look at nope')
    expect(model.requests[1].body.messages[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'toolu_1', is_error: true })
    const truncated = await chat.ask('Look at the document')
    expect(truncated.map(event => event.type)).toEqual(['error', 'done'])
    expect(truncated[0].message).toBe('The model reply was cut off by the length limit; stopped this reply')
    expect(app.received.map(request => request.command)).toEqual(['get_node'])
  })

  it('sends thinking blocks back unchanged during the tool loop', async () => {
    const app = await startApp()
    const content = [
      { type: 'thinking', thinking: '', signature: 'sig_1' },
      { type: 'text', text: 'Let me check.' },
      { type: 'tool_use', id: 'toolu_1', name: 'design_get_state', input: {} },
    ]
    const model = await fakeModel([{ body: { content, stop_reason: 'tool_use' } }, anthropicText('One frame.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    await chat.ask('look at the document')
    expect(model.requests[1].body.messages[1]).toEqual({ role: 'assistant', content })
  })

  it('reports refusal and pause_turn instead of ending the reply silently', async () => {
    const model = await fakeModel([
      { body: { content: [], stop_reason: 'refusal', stop_details: { type: 'refusal', category: 'cyber' } } },
      { body: { content: [{ type: 'text', text: 'Working on it' }], stop_reason: 'pause_turn' } },
      anthropicText('Hello.'),
    ])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    const refused = await chat.ask('one')
    expect(refused.map(event => event.type)).toEqual(['error', 'done'])
    expect(refused[0].message).toBe('The model declined this request; stopped this reply')
    const paused = await chat.ask('two')
    expect(paused.map(event => event.type)).toEqual(['error', 'done'])
    expect(paused[0].message).toBe('The model paused before finishing; stopped this reply')
    // Neither failed reply is written to the history, so the next request is still valid.
    await chat.ask('three')
    expect(model.requests[2].body.messages).toEqual([{ role: 'user', content: [{ type: 'text', text: 'one' }, { type: 'text', text: 'two' }, { type: 'text', text: 'three' }] }])
  })

  it('HTTP errors are shown in English', async () => {
    const model = await fakeModel([{ status: 529, body: { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } } }])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect((await chat.ask('Hello')).find(event => event.type === 'error')?.message).toBe('Model API error (HTTP 529): Overloaded')
  })
})

/** Runs the harness with --list-models, returning its single line of output and the exit code. */
async function listModels(env: Record<string, string>) {
  const child = spawn(process.execPath, [harness, '--list-models'], { env: { PATH: process.env.PATH ?? '', ...env }, stdio: ['ignore', 'pipe', 'pipe'] })
  let output = ''
  child.stdout!.setEncoding('utf8')
  child.stdout!.on('data', chunk => { output += chunk })
  const code = await new Promise<number | null>(resolve => child.once('exit', resolve))
  return { code, output, event: JSON.parse(output.trim()) }
}

describe('Agent harness: listing available models', () => {
  it('reads /models from an OpenAI-compatible API and includes the default model', async () => {
    const model = await fakeModel([{ body: { object: 'list', data: [{ id: 'deepseek-chat' }, { id: 'deepseek-reasoner' }, { id: 'deepseek-chat' }] } }])
    const result = await listModels({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: `${model.baseUrl}/`, UI_ATLAS_API_KEY: KEY })
    expect(result.code).toBe(0)
    expect(result.event).toEqual({ type: 'models', models: ['deepseek-chat', 'deepseek-reasoner'], default: 'deepseek-chat' })
    expect(model.requests[0].url).toBe('/models')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
  })

  it('reads /models for the OpenAI Responses provider too', async () => {
    const model = await fakeModel([{ body: { data: [{ id: 'gpt-5.3-codex' }] } }])
    const result = await listModels({ UI_ATLAS_PROVIDER: 'openai', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY })
    expect(result.event).toEqual({ type: 'models', models: ['gpt-5.3-codex'], default: 'gpt-5.3-codex' })
    expect(model.requests[0].url).toBe('/models')
  })

  it('reads /v1/models from Anthropic with its own auth headers', async () => {
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

const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

/** A fake App whose node_snapshot returns a 1×1 PNG. */
const startSnapshotApp = () => startApp(request => request.command === 'node_snapshot'
  ? { ok: true, result: { id: request.args.id, width: 780, height: 1688, mimeType: 'image/png', data: PNG } }
  : { ok: false, error: `Unhandled command: ${request.command}` })

describe('Agent harness: design_snapshot images', () => {
  it('sends the snapshot image to Anthropic inside the tool result', async () => {
    const app = await startSnapshotApp()
    const model = await fakeModel([anthropicTool('toolu_1', 'design_snapshot', { id: 'home' }), anthropicText('Looks right.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Check the home page')
    expect(model.requests[1].body.messages[2].content[0]).toEqual({
      type: 'tool_result', tool_use_id: 'toolu_1',
      content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: PNG } },
        { type: 'text', text: 'Snapshot of layer home (780×1688)' },
      ],
    })
    expect(model.requests[0].body.system).toMatch(/design_snapshot to check the result/)
    // The chat panel only shows the text; the image data is not sent to the App.
    expect(events.find(event => event.type === 'tool_result')).toMatchObject({ ok: true, text: 'Snapshot of layer home (780×1688)' })
  })

  it('sends the snapshot image to the OpenAI Responses API inside the function call output', async () => {
    const app = await startSnapshotApp()
    const model = await fakeModel([responsesTool('call_1', 'design_snapshot', { id: 'home' }), responsesText('Looks right.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'openai', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    await chat.ask('Check the home page')
    expect(model.requests[1].body.input.at(-1)).toEqual({
      type: 'function_call_output', call_id: 'call_1',
      output: [
        { type: 'input_image', image_url: `data:image/png;base64,${PNG}` },
        { type: 'input_text', text: 'Snapshot of layer home (780×1688)' },
      ],
    })
    expect(model.requests[0].body.instructions).toMatch(/design_snapshot to check the result/)
  })

  it('leaves out a snapshot too large for the model API and asks for a smaller scale', async () => {
    // Only the PNG header matters here: signature, IHDR length and tag, then width 9000 and height 100.
    const header = Buffer.alloc(24)
    Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex').copy(header)
    header.writeUInt32BE(9000, 16)
    header.writeUInt32BE(100, 20)
    const huge = header.toString('base64')
    const app = await startApp(() => ({ ok: true, result: { id: 'home', width: 9000, height: 100, mimeType: 'image/png', data: huge } }))
    const model = await fakeModel([anthropicTool('toolu_1', 'design_snapshot', { id: 'home', scale: 4 }), anthropicText('Too large.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'anthropic', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    await chat.ask('Check the home page')
    const result = model.requests[1].body.messages[2].content[0]
    expect(result.content).toMatch(/^Snapshot of layer home \(9000×100\)\n.*larger than 8000 px.*smaller scale/)
    expect(JSON.stringify(model.requests[1].body)).not.toContain(huge)
  })

  it('tells a provider that cannot receive images that the snapshot image was left out', async () => {
    const app = await startSnapshotApp()
    const model = await fakeModel([openaiTool('call_1', 'design_snapshot', { id: 'home' }), openaiText('I cannot see it.')])
    const chat = await startHarness({ UI_ATLAS_PROVIDER: 'deepseek', UI_ATLAS_BASE_URL: model.baseUrl, UI_ATLAS_API_KEY: KEY, UI_ATLAS_CONTROL_SOCKET: app.socketPath })
    await chat.ask('Check the home page')
    const result = model.requests[1].body.messages.at(-1)
    expect(result).toMatchObject({ role: 'tool', tool_call_id: 'call_1' })
    expect(result.content).toContain('Snapshot of layer home (780×1688)')
    expect(result.content).toMatch(/image was left out.*cannot receive images/)
    expect(JSON.stringify(model.requests[1].body)).not.toContain(PNG)
    const system = model.requests[0].body.messages[0].content
    expect(system).not.toMatch(/design_snapshot to check the result/)
    expect(system).toMatch(/cannot see images/)
    expect(system).toMatch(/design_get_node/)
  })
})
