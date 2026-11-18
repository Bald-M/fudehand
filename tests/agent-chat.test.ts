import { afterEach, describe, expect, it } from 'vitest'
import { spawn, type ChildProcess } from 'node:child_process'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fakeApp, type ControlRequest } from './helpers/fake-app'
import { designGuidance } from '../scripts/design-guidance.mjs'

const harness = fileURLToPath(new URL('../scripts/agent-chat.mjs', import.meta.url))
const cleanup: (() => Promise<unknown>)[] = []
afterEach(async () => { for (const action of cleanup.splice(0).reverse()) await action() })

const KEY = 'sk-test-secret-0123456789'

/** `json` answers a streaming request with a plain JSON body; `sse` sends that raw event stream instead of one built from `body`. */
type Reply = { status?: number, body: unknown, delayMs?: number, chunkDelayMs?: number, json?: boolean, sse?: string }
type Captured = { url: string, headers: IncomingMessage['headers'], body: any }

const pieces = (text: string) => text ? [text.slice(0, Math.ceil(text.length / 2)), text.slice(Math.ceil(text.length / 2))].filter(Boolean) : []

/** Splits a complete response body into the event stream the provider's API would send for it. */
function streamEvents(url: string, body: any): string[] {
  let events: any[]
  if (url === '/chat/completions') {
    const choice = body.choices[0]
    const message = choice.message
    events = [
      ...pieces(message.content ?? '').map(content => ({ choices: [{ delta: { content } }] })),
      ...(message.tool_calls ?? []).flatMap((call: any, index: number) => [
        { choices: [{ delta: { tool_calls: [{ index, id: call.id, type: 'function', function: { name: call.function.name, arguments: '' } }] } }] },
        ...pieces(call.function.arguments).map(part => ({ choices: [{ delta: { tool_calls: [{ index, function: { arguments: part } }] } }] })),
      ]),
      { choices: [{ delta: {}, finish_reason: choice.finish_reason ?? (message.tool_calls ? 'tool_calls' : 'stop') }] },
      // With stream_options.include_usage, the usage arrives in a last chunk that has no choices.
      ...(body.usage ? [{ choices: [], usage: body.usage }] : []),
    ]
    return [...events.map(event => `data: ${JSON.stringify(event)}\n\n`), 'data: [DONE]\n\n']
  }
  if (url === '/responses') {
    events = [
      ...body.output.filter((item: any) => item.type === 'message').flatMap((item: any) => item.content)
        .flatMap((part: any) => pieces(part.text)).map((delta: string) => ({ type: 'response.output_text.delta', delta })),
      { type: body.status === 'incomplete' ? 'response.incomplete' : 'response.completed', response: body },
    ]
  } else {
    const { output_tokens, ...inputUsage } = body.usage ?? {}
    events = [
      { type: 'message_start', message: { role: 'assistant', content: [], ...(body.usage ? { usage: inputUsage } : {}) } },
      ...body.content.flatMap((block: any, index: number) => {
        const deltas = block.type === 'text' ? pieces(block.text).map(text => ({ type: 'text_delta', text }))
          : block.type === 'tool_use' ? pieces(JSON.stringify(block.input)).map(partial_json => ({ type: 'input_json_delta', partial_json }))
          : [...pieces(block.thinking).map(thinking => ({ type: 'thinking_delta', thinking })), { type: 'signature_delta', signature: block.signature }]
        const start = block.type === 'text' ? { type: 'text', text: '' }
          : block.type === 'tool_use' ? { ...block, input: {} } : { type: 'thinking', thinking: '', signature: '' }
        return [
          { type: 'content_block_start', index, content_block: start },
          ...deltas.map(delta => ({ type: 'content_block_delta', index, delta })),
          { type: 'content_block_stop', index },
        ]
      }),
      { type: 'message_delta', delta: { stop_reason: body.stop_reason }, ...(body.usage ? { usage: { output_tokens } } : {}) },
      { type: 'message_stop' },
    ]
  }
  return events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`)
}

/**
 * A local fake model service: returns the preset responses in order and records the requests it receives.
 * A request with `stream: true` gets the response as an event stream, as the real APIs send it.
 */
async function fakeModel(replies: Reply[]) {
  const requests: Captured[] = []
  const server = createServer(async (request: IncomingMessage, response: ServerResponse) => {
    let raw = ''
    for await (const chunk of request) raw += chunk
    const received = JSON.parse(raw || '{}')
    requests.push({ url: request.url ?? '', headers: request.headers, body: received })
    const reply = replies.shift() ?? { status: 500, body: { error: { message: 'No more preset responses' } } }
    if (reply.delayMs) await new Promise(resolve => setTimeout(resolve, reply.delayMs))
    if (response.destroyed) return
    if (received.stream && !reply.json && (reply.status ?? 200) === 200) {
      response.writeHead(200, { 'content-type': 'text/event-stream' })
      for (const chunk of reply.sse ? [reply.sse] : streamEvents(request.url ?? '', reply.body)) {
        if (reply.chunkDelayMs) await new Promise(resolve => setTimeout(resolve, reply.chunkDelayMs))
        if (response.destroyed) return
        response.write(chunk)
      }
      response.end()
      return
    }
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
    env: { PATH: process.env.PATH ?? '', FUDEHAND_CONTROL_SOCKET: join(root, 'missing.sock'), ...env },
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
    /** Sends one user message and waits for the turn to end, returning the turn's events without the streamed text deltas. */
    async ask(text: string, extra: object = {}) {
      const from = events.length
      child.stdin!.write(JSON.stringify({ type: 'user', text, ...extra }) + '\n')
      await until(event => event.type === 'done', from)
      return events.slice(from).filter(event => event.type !== 'assistant_delta')
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

describe('Design guidance', () => {
  it('gives the design guidance its five-step process, its quality floor, and nothing the layer model cannot do', () => {
    for (const step of ['1. Ground it.', '2. Plan.', '3. Review.', '4. Build.', '5. Critique.']) expect(designGuidance).toContain(step)
    expect(designGuidance).toMatch(/4–6 named hex colors/)
    expect(designGuidance).toMatch(/state (that|the) assumption in your reply/)
    expect(designGuidance).toMatch(/Quality floor/)
    expect(designGuidance).toMatch(/Lorem ipsum/)
    expect(designGuidance).toMatch(/At most two font families/)
    expect(designGuidance).toMatch(/user's own words take precedence/)
    expect(designGuidance).not.toMatch(/\bCSS\b|selector|animation|motion|hover|keyboard|focus ring|responsive|breakpoint/i)
    // MCP clients such as Claude Code cut a server's instructions off at about 2,048 characters.
    expect(designGuidance.length).toBeLessThan(2000)
    // The Chinese range is deliberate: the guidance is written in English only.
    expect(designGuidance).not.toMatch(/[一-鿿]/)
  })
})

describe('Agent harness: OpenAI-compatible API (DeepSeek / OpenAI)', () => {
  it('holds a multi-turn conversation and reads the design document through tools', async () => {
    const app = await startApp()
    const model = await fakeModel([openaiTool('call_1', 'design_get_state', {}), openaiText('The document has 1 frame: Demo page.'), openaiText('You are welcome.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
    expect(system).toContain(designGuidance)
  })

  it('hands the App error to the model when an edit is rejected, sending only that one command', async () => {
    const app = await startApp(() => ({ ok: false, error: 'Layer not found: nope' }))
    const model = await fakeModel([
      openaiTool('call_1', 'design_update_node', { id: 'nope', changes: { name: 'Title' } }),
      openaiText('There is no such layer.'),
    ])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Rename nope to Title')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false })
    expect(events[1].text).toContain('Layer not found: nope')
    expect(model.requests[1].body.messages.at(-1).content).toContain('Layer not found: nope')
    expect(app.received).toEqual([{ id: expect.anything(), command: 'update_node', args: { id: 'nope', changes: { name: 'Title' } } }])
  })

  it('canvas tools return an English error when the App is not running', async () => {
    const model = await fakeModel([openaiTool('call_1', 'canvas_focus_node', { id: 'home' }), openaiText('The App is not running.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    const events = await chat.ask('Focus the home page')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false, text: 'Fudehand is not running' })
  })

  it('HTTP errors, network failures and a missing key show English errors', async () => {
    const model = await fakeModel([
      { status: 401, body: { error: { message: `Incorrect API key provided: ${KEY}` } } },
      { status: 429, body: { error: { message: 'rate limited' } } },
      { status: 402, body: { error: { message: 'Insufficient Balance' } } },
      { status: 500, body: { error: { message: 'boom' } } },
    ])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    const messages = []
    for (let i = 0; i < 4; i++) messages.push((await chat.ask('Hello')).find(event => event.type === 'error')?.message)
    expect(messages).toEqual(['Invalid API key or insufficient permissions', 'Quota exceeded or too many requests', 'Quota exceeded or too many requests', 'Model API error (HTTP 500): boom'])

    const offline = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: 'http://127.0.0.1:9', FUDEHAND_API_KEY: KEY })
    expect((await offline.ask('Hello')).find(event => event.type === 'error')?.message).toMatch(/^Could not connect to the model API/)

    const missing = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl })
    expect((await missing.ask('Hello')).find(event => event.type === 'error')?.message).toBe('No API key configured')
  })

  it('executes no further tool calls after a stop', async () => {
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const model = await fakeModel([{ ...openaiTool('call_1', 'design_delete_nodes', { ids: ['home'] }), delayMs: 800 }])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Delete the home page')
    expect(events[1]).toMatchObject({ type: 'tool_result', ok: false, text: 'Tool arguments are not valid JSON' })
    expect(app.received).toEqual([])
  })

  it('keeps an empty reply out of the history and replaces the history when a conversation is loaded', async () => {
    const model = await fakeModel([{ body: { choices: [{ message: { role: 'assistant', content: null } }] } }, openaiText('Second'), openaiText('After clearing')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await chat.ask('one')
    await chat.ask('two')
    expect(model.requests[1].body.messages.map((message: any) => message.role)).toEqual(['system', 'user', 'user'])
    chat.send({ type: 'load', messages: [] })
    await chat.ask('three')
    expect(model.requests[2].body.messages.map((message: any) => message.content)).toEqual([expect.any(String), 'three'])
    chat.send({ type: 'load', messages: [{ role: 'user', text: 'earlier question' }, { role: 'assistant', text: 'earlier answer' }, { role: 'tool', text: 'ignored' }] })
    await chat.ask('four')
    expect(model.requests[3].body.messages.slice(1)).toEqual([
      { role: 'user', content: 'earlier question' }, { role: 'assistant', content: 'earlier answer' }, { role: 'user', content: 'four' },
    ])
  })

  it('streams the reply as text deltas before the complete text', async () => {
    const model = await fakeModel([openaiText('Hello there, world.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await chat.ask('Hi')
    expect(model.requests[0].body.stream).toBe(true)
    expect(chat.events.map(event => event.type)).toEqual(['assistant_delta', 'assistant_delta', 'assistant', 'done'])
    expect(chat.events.slice(0, 2).map(event => event.text).join('')).toBe('Hello there, world.')
    expect(chat.events[2].text).toBe('Hello there, world.')
  })

  it('reads a plain JSON body when the endpoint ignores streaming', async () => {
    const model = await fakeModel([{ ...openaiText('Not streamed.'), json: true }])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await chat.ask('Hi')
    expect(chat.events).toEqual([{ type: 'assistant', text: 'Not streamed.' }, { type: 'done', stopped: false }])
  })

  it('keeps the text received before a stop in the history', async () => {
    const model = await fakeModel([{ ...openaiText('Hello world'), chunkDelayMs: 400 }, openaiText('OK')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    chat.send({ type: 'user', text: 'Say hello' })
    await chat.until(event => event.type === 'assistant_delta')
    chat.send({ type: 'stop' })
    const done = await chat.until(event => event.type === 'done')
    expect(done.stopped).toBe(true)
    expect(chat.events.map(event => event.type)).toEqual(['assistant_delta', 'done'])
    await chat.ask('Continue')
    expect(model.requests[1].body.messages.slice(1)).toEqual([
      { role: 'user', content: 'Say hello' }, { role: 'assistant', content: 'Hello ' }, { role: 'user', content: 'Continue' },
    ])
  })

  it('reports an error sent in the middle of a stream', async () => {
    const sse = `data: ${JSON.stringify({ choices: [{ delta: { content: 'Half' } }] })}\n\ndata: ${JSON.stringify({ error: { message: 'upstream overloaded' } })}\n\n`
    const model = await fakeModel([{ body: null, sse }])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    const events = await chat.ask('Hi')
    expect(events).toEqual([{ type: 'error', message: 'Model API error: upstream overloaded' }, { type: 'done', stopped: false }])
  })

  it('reports a stream that ends before the reply is complete instead of accepting it', async () => {
    const cut = `data: ${JSON.stringify({ choices: [{ delta: { content: 'Half an ans' } }] })}\n\n`
    // The closing event has no blank line after it; it still counts.
    const whole = `data: ${JSON.stringify({ choices: [{ delta: { content: 'Whole' } }] })}\n\ndata: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: 'stop' }] })}`
    const model = await fakeModel([{ body: null, sse: cut }, { body: null, sse: whole }])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect(await chat.ask('Hi')).toEqual([{ type: 'error', message: 'The model reply ended before it was complete; stopped this reply' }, { type: 'done', stopped: false }])
    expect(await chat.ask('Again')).toEqual([{ type: 'assistant', text: 'Whole' }, { type: 'done', stopped: false }])
  })

  it('keeps parallel tool calls apart when the stream gives them no index', async () => {
    const app = await startApp()
    const call = (id: string) => ({ choices: [{ delta: { tool_calls: [{ id, type: 'function', function: { name: 'design_get_state', arguments: '{}' } }] } }] })
    const sse = [call('call_a'), call('call_b'), { choices: [{ delta: { content: '' }, finish_reason: 'tool_calls' }] }].map(event => `data: ${JSON.stringify(event)}\n\n`).join('')
    const model = await fakeModel([{ body: null, sse }, openaiText('Done.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    await chat.ask('Look twice')
    // The empty text delta is not reported either.
    expect(chat.events.map(event => event.type).slice(0, 4)).toEqual(['tool_call', 'tool_result', 'tool_call', 'tool_result'])
    expect(chat.events.filter(event => event.type === 'tool_call').map(event => event.id)).toEqual(['call_a', 'call_b'])
    expect(app.received.map(request => request.command)).toEqual(['get_state', 'get_state'])
  })

  it('tells the model which layers the user has selected', async () => {
    const model = await fakeModel([openaiText('Done.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await chat.ask('Make it blue', { context: [{ id: 'n1', name: 'Hero "card"', type: 'frame' }, { id: 'n2', name: 'Title', type: 'text' }] })
    expect(model.requests[0].body.messages[1].content).toBe(
      'The user has these layers selected: "Hero \\"card\\"" (frame, id n1), "Title" (text, id n2)\n\nMake it blue')
  })

  it('tells the model which provider and model it runs on', async () => {
    const model = await fakeModel([openaiText('Done.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_MODEL: 'deepseek-v4-pro', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await chat.ask('Which model are you?')
    expect(model.requests[0].body.messages[0].content).toContain('You are running on the model "deepseek-v4-pro" (provider setting: deepseek).')

    const claude = await fakeModel([anthropicText('Done.')])
    const other = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: claude.baseUrl, FUDEHAND_API_KEY: KEY })
    await other.ask('Which model are you?')
    expect(claude.requests[0].body.system).toContain('You are running on the model "claude-sonnet-5-5" (provider setting: anthropic).')
  })

  it('sends a validly formatted history in the next request after a stop', async () => {
    const app = await startApp()
    const model = await fakeModel([{ ...openaiTool('call_1', 'design_get_state', {}), delayMs: 600 }, openaiText('OK')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Keep checking')
    expect(events.at(-2)).toEqual({ type: 'error', message: 'Too many tool-call rounds; stopped this reply' })
    expect(model.requests).toHaveLength(16)
    expect(app.received).toHaveLength(16)
  })

  it('exits after stdin closes and keeps the key out of the output', async () => {
    const model = await fakeModel([{ status: 401, body: { error: { message: `bad key ${KEY}` } } }])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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

describe('Agent harness: streaming from the Responses and Anthropic APIs', () => {
  it('streams Responses API text and reports a reply cut off by the length limit', async () => {
    const model = await fakeModel([responsesText('Two frames here.'), { body: { status: 'incomplete', output: [] } }])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await chat.ask('Hi')
    expect(model.requests[0].body.stream).toBe(true)
    expect(chat.events.map(event => event.type)).toEqual(['assistant_delta', 'assistant_delta', 'assistant', 'done'])
    expect(chat.events[2].text).toBe('Two frames here.')
    expect((await chat.ask('More'))[0]).toEqual({ type: 'error', message: 'The model reply was cut off by the length limit; stopped this reply' })
  })

  it('streams Anthropic text and assembles tool arguments from partial JSON', async () => {
    const app = await startApp(() => ({ ok: false, error: 'Layer not found: nope' }))
    const model = await fakeModel([anthropicTool('toolu_1', 'design_get_node', { id: 'nope' }), anthropicText('No such layer.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    await chat.ask('Look at nope')
    expect(model.requests[0].body.stream).toBe(true)
    expect(chat.events.map(event => event.type)).toEqual(
      ['assistant_delta', 'assistant_delta', 'assistant', 'tool_call', 'tool_result', 'assistant_delta', 'assistant_delta', 'assistant', 'done'])
    expect(chat.events[3]).toMatchObject({ name: 'design_get_node', args: { id: 'nope' } })
    expect(app.received).toEqual([{ id: expect.anything(), command: 'get_node', args: { id: 'nope' } }])
  })
})

describe('Agent harness: an Anthropic stream cut short', () => {
  it('does not run a tool whose arguments were still arriving', async () => {
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const events = [
      { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 'toolu_1', name: 'design_delete_nodes', input: {} } },
      { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"ids":["ho' } },
    ]
    const model = await fakeModel([{ body: null, sse: events.map(event => `data: ${JSON.stringify(event)}\n\n`).join('') }])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    expect((await chat.ask('Delete home')).map(event => event.type)).toEqual(['error', 'done'])
    expect(app.received).toEqual([])
  })
})

describe('Agent harness: Anthropic Messages API', () => {
  it('holds a multi-turn conversation and reads the design document through tools', async () => {
    const app = await startApp()
    const model = await fakeModel([anthropicTool('toolu_1', 'design_get_state', {}), anthropicText('There is 1 frame.'), anthropicText('OK.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    await chat.ask('look at the document')
    expect(model.requests[1].body.messages[1]).toEqual({ role: 'assistant', content })
  })

  it('reports refusal and pause_turn instead of ending the reply silently', async () => {
    const model = await fakeModel([
      { body: { content: [], stop_reason: 'refusal', stop_details: { type: 'refusal', category: 'cyber' } } },
      { body: { content: [{ type: 'text', text: 'Working on it' }], stop_reason: 'pause_turn' } },
      anthropicText('Hello.'),
    ])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect((await chat.ask('Hello')).find(event => event.type === 'error')?.message).toBe('Model API error (HTTP 529): Overloaded')
  })
})

/** Adds the provider's usage report to a preset reply. */
const withUsage = (reply: { body: object }, usage: object) => ({ body: { ...reply.body, usage } })

describe('Agent harness: token usage', () => {
  const deepseek = (baseUrl: string, extra: Record<string, string> = {}) =>
    startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: baseUrl, FUDEHAND_API_KEY: KEY, ...extra })

  it('reports the usage a Chat Completions stream ends with', async () => {
    const model = await fakeModel([
      withUsage(openaiText('Hi.'), { prompt_tokens: 120, completion_tokens: 30, prompt_cache_hit_tokens: 100 }),
      withUsage(openaiText('Again.'), { prompt_tokens: 50, completion_tokens: 5, prompt_tokens_details: { cached_tokens: 7 } }),
    ])
    const chat = await deepseek(model.baseUrl)
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 120, output: 30, cached: 100 } })
    expect(model.requests[0].body.stream_options).toEqual({ include_usage: true })
    expect((await chat.ask('Again')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 50, output: 5, cached: 7 } })
  })

  it('reports Responses API usage', async () => {
    const model = await fakeModel([withUsage(responsesText('Hi.'), { input_tokens: 200, output_tokens: 40, input_tokens_details: { cached_tokens: 150 } })])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 200, output: 40, cached: 150 } })
  })

  it('counts Anthropic cache tokens as input', async () => {
    const model = await fakeModel([withUsage(anthropicText('Hi.'), { input_tokens: 10, cache_creation_input_tokens: 20, cache_read_input_tokens: 300, output_tokens: 50 })])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 330, output: 50, cached: 300 } })
  })

  it('reads usage from a plain JSON body', async () => {
    const model = await fakeModel([
      { ...withUsage(openaiText('Hi.'), { prompt_tokens: 120, completion_tokens: 30 }), json: true },
      { ...withUsage(anthropicText('Hi.'), { input_tokens: 10, cache_read_input_tokens: 300, output_tokens: 50 }), json: true },
    ])
    expect((await (await deepseek(model.baseUrl)).ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 120, output: 30, cached: 0 } })
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 310, output: 50, cached: 300 } })
  })

  it('reports no usage when the API sends none or sends it malformed', async () => {
    const model = await fakeModel([openaiText('Hi.'), withUsage(openaiText('Again.'), { prompt_tokens: 'many' })])
    const chat = await deepseek(model.baseUrl)
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false })
    expect((await chat.ask('Again')).at(-1)).toEqual({ type: 'done', stopped: false })
  })

  it('adds up the usage of every round of a reply', async () => {
    const app = await startApp()
    const model = await fakeModel([
      withUsage(openaiTool('call_1', 'design_get_state', {}), { prompt_tokens: 100, completion_tokens: 10 }),
      withUsage(openaiText('Done.'), { prompt_tokens: 150, completion_tokens: 20, prompt_cache_hit_tokens: 90 }),
    ])
    const chat = await deepseek(model.baseUrl, { FUDEHAND_CONTROL_SOCKET: app.socketPath })
    expect((await chat.ask('Look')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 250, output: 30, cached: 90 } })
  })

  it('reports no usage when one round did not report any', async () => {
    const app = await startApp()
    const model = await fakeModel([withUsage(openaiTool('call_1', 'design_get_state', {}), { prompt_tokens: 100, completion_tokens: 10 }), openaiText('Done.')])
    const chat = await deepseek(model.baseUrl, { FUDEHAND_CONTROL_SOCKET: app.socketPath })
    expect((await chat.ask('Look')).at(-1)).toEqual({ type: 'done', stopped: false })
  })

  it('reports the completed rounds when the reply is stopped', async () => {
    const app = await startApp()
    const model = await fakeModel([
      withUsage(openaiTool('call_1', 'design_get_state', {}), { prompt_tokens: 100, completion_tokens: 10 }),
      { ...openaiText('Too late.'), delayMs: 1500 },
    ])
    const chat = await deepseek(model.baseUrl, { FUDEHAND_CONTROL_SOCKET: app.socketPath })
    chat.send({ type: 'user', text: 'Look' })
    await chat.until(event => event.type === 'tool_result')
    chat.send({ type: 'stop' })
    expect(await chat.until(event => event.type === 'done')).toEqual({ type: 'done', stopped: true, usage: { input: 100, output: 10, cached: 0 } })
  })

  it('counts a round whose reply was cut off or declined', async () => {
    const app = await startApp()
    const model = await fakeModel([
      withUsage(anthropicTool('toolu_1', 'design_get_state', {}), { input_tokens: 100, output_tokens: 10 }),
      { body: { content: [{ type: 'text', text: 'Half' }], stop_reason: 'max_tokens', usage: { input_tokens: 150, output_tokens: 16000 } } },
      { body: { choices: [{ finish_reason: 'length', message: { role: 'assistant', content: 'Half' } }], usage: { prompt_tokens: 40, completion_tokens: 8 } } },
    ])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Look')
    expect(events.slice(-2)).toEqual([
      { type: 'error', message: 'The model reply was cut off by the length limit; stopped this reply' },
      { type: 'done', stopped: false, usage: { input: 250, output: 16010, cached: 0 } },
    ])
    expect((await (await deepseek(model.baseUrl)).ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 40, output: 8, cached: 0 } })
  })

  it('still reports usage when a later round fails', async () => {
    const app = await startApp()
    const model = await fakeModel([withUsage(openaiTool('call_1', 'design_get_state', {}), { prompt_tokens: 100, completion_tokens: 10 }), { status: 500, body: {} }])
    const chat = await deepseek(model.baseUrl, { FUDEHAND_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Look')
    expect(events.slice(-2).map(event => event.type)).toEqual(['error', 'done'])
    expect(events.at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 100, output: 10, cached: 0 } })
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
    const result = await listModels({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: `${model.baseUrl}/`, FUDEHAND_API_KEY: KEY })
    expect(result.code).toBe(0)
    expect(result.event).toEqual({ type: 'models', models: ['deepseek-chat', 'deepseek-reasoner'], default: 'deepseek-chat' })
    expect(model.requests[0].url).toBe('/models')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
  })

  it('reads /models for the OpenAI Responses provider too', async () => {
    const model = await fakeModel([{ body: { data: [{ id: 'gpt-5.3-codex' }] } }])
    const result = await listModels({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect(result.event).toEqual({ type: 'models', models: ['gpt-5.3-codex'], default: 'gpt-5.3-codex' })
    expect(model.requests[0].url).toBe('/models')
  })

  it('reads /v1/models from Anthropic with its own auth headers', async () => {
    const model = await fakeModel([{ body: { data: [{ id: 'claude-opus-5-5', type: 'model' }, { id: 'claude-sonnet-5-5', type: 'model' }], has_more: false } }])
    const result = await listModels({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect(result.event).toEqual({ type: 'models', models: ['claude-opus-5-5', 'claude-sonnet-5-5'], default: 'claude-sonnet-5-5' })
    expect(model.requests[0].url).toBe('/v1/models?limit=1000')
    expect(model.requests[0].headers['x-api-key']).toBe(KEY)
    expect(model.requests[0].headers['anthropic-version']).toBe('2023-06-01')
  })

  it('errors are shown in English and the key never appears in the output', async () => {
    const model = await fakeModel([{ status: 401, body: { error: { message: `bad key ${KEY}` } } }, { status: 404, body: { error: { message: `no route for ${KEY}` } } }])
    const unauthorized = await listModels({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect(unauthorized.event).toEqual({ type: 'error', message: 'Invalid API key or insufficient permissions' })
    const missing = await listModels({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect(missing.event.type).toBe('error')
    expect(missing.output).not.toContain(KEY)
    expect((await listModels({ FUDEHAND_PROVIDER: 'deepseek' })).event).toEqual({ type: 'error', message: 'No API key configured' })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
    await chat.ask('Check the home page')
    const result = model.requests[1].body.messages[2].content[0]
    expect(result.content).toMatch(/^Snapshot of layer home \(9000×100\)\n.*larger than 8000 px.*smaller scale/)
    expect(JSON.stringify(model.requests[1].body)).not.toContain(huge)
  })

  it('tells a provider that cannot receive images that the snapshot image was left out', async () => {
    const app = await startSnapshotApp()
    const model = await fakeModel([openaiTool('call_1', 'design_snapshot', { id: 'home' }), openaiText('I cannot see it.')])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: app.socketPath })
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
