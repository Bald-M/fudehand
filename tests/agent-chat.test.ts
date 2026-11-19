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
 * Next-message prediction requests are recorded in `predictions` and answered from `predictionReplies`, with an error when none is left.
 */
async function fakeModel(replies: Reply[], predictionReplies: Reply[] = []) {
  const requests: Captured[] = []
  const predictions: Captured[] = []
  const server = createServer(async (request: IncomingMessage, response: ServerResponse) => {
    let raw = ''
    for await (const chunk of request) raw += chunk
    const received = JSON.parse(raw || '{}')
    // The request the harness makes after a reply to predict the next message is answered from its own list.
    const prediction = raw.includes('Predict the next message')
    ;(prediction ? predictions : requests).push({ url: request.url ?? '', headers: request.headers, body: received })
    const reply = (prediction ? predictionReplies : replies).shift() ?? { status: 500, body: { error: { message: 'No more preset responses' } } }
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
  return { requests, predictions, baseUrl: `http://127.0.0.1:${address.port}` }
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
    // Real icons instead of stand-ins, from the library of the prototype's platform.
    for (const word of ['design_search_icons', 'sf', 'material-', 'weui', 'lucide']) expect(designGuidance).toContain(word)
    expect(designGuidance).not.toMatch(/\bCSS\b|\bHTML\b|oklch|text-wrap|semantic|selector|animation|motion|transition|hover|keyboard|focus ring|focus state|disabled|shadow|interaction state|responsive|breakpoint/i)
    // The Chinese range is deliberate: the guidance is written in English only.
    expect(designGuidance).not.toMatch(/[一-鿿]/)
  })

  it('keeps the guidance within its length limits, with the five-step core first', () => {
    expect(designGuidance.length).toBeLessThanOrEqual(8000)
    // MCP clients such as Claude Code cut a server's instructions off at about 2,048 characters: what comes before the
    // design principles must survive that cut whole.
    expect(designGuidance.indexOf('## Design principles')).toBeGreaterThan(0)
    const core = designGuidance.slice(0, designGuidance.indexOf('## Design principles')).trimEnd()
    expect(core).toMatch(/5\. Critique\./)
    expect(core).toMatch(/Generic looks to avoid/)
    expect(core.length).toBeLessThan(2000)
  })

  it('adds design principles and a self-review checklist adapted for the layer model', () => {
    expect(designGuidance).toMatch(/## Design principles/)
    expect(designGuidance).toMatch(/## Self-review checklist/)
    expect(designGuidance.indexOf('## Design principles')).toBeLessThan(designGuidance.indexOf('## Self-review checklist'))
    expect(designGuidance).toMatch(/one primary action/)
    expect(designGuidance).toMatch(/spacing scale/)
    expect(designGuidance).toMatch(/4\.5:1/)
    expect(designGuidance).toMatch(/44×44/)
    expect(designGuidance).toMatch(/[Gg]radients/)
    expect(designGuidance).toMatch(/[Ee]moji/)
    // Trying it in the App: "buttons that lead nowhere" made the Agent build each button's destination screen and run out of rounds.
    expect(designGuidance).toMatch(/Build only the screens the user asked for/)
    expect(designGuidance).not.toMatch(/lead nowhere/)
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
    expect(model.requests[0].body.tools.map((tool: any) => tool.function.name)).toEqual(expect.arrayContaining(['design_create_node', 'style_list', 'style_read']))
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
    // Stop only once the request is with the model, which is still holding its tool call; a stop before then sends no request at all.
    while (!model.requests.length) await new Promise(resolve => setTimeout(resolve, 10))
    chat.send({ type: 'stop' })
    await chat.until(event => event.type === 'done', from)
    await chat.ask('Continue')
    expect(model.requests).toHaveLength(2)
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

const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

describe('Agent harness: next-message prediction', () => {
  const env = (model: { baseUrl: string }, provider = 'deepseek') => ({ FUDEHAND_PROVIDER: provider, FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })

  it('suggests the next message after a reply, asking without tools and outside the history', async () => {
    const model = await fakeModel([openaiText('Done, the title is 32 pt.'), openaiText('OK')], [openaiText('  "Make the subtitle bigger too"\nSecond line')])
    const chat = await startHarness(env(model))
    await chat.ask('Make the title bigger')
    const suggestion = await chat.until(event => event.type === 'suggestion')
    expect(suggestion).toEqual({ type: 'suggestion', text: 'Make the subtitle bigger too' })
    expect(chat.events.indexOf(suggestion)).toBeGreaterThan(chat.events.findIndex(event => event.type === 'done'))
    const { body } = model.predictions[0]
    expect(body.tools).toBeUndefined()
    expect(body.messages.map((message: any) => message.role)).toEqual(['system', 'user'])
    expect(body.messages[1].content).toContain('User: Make the title bigger')
    expect(body.messages[1].content).toContain('Assistant: Done, the title is 32 pt.')
    await chat.ask('Thanks')
    expect(model.requests[1].body.messages.slice(1).map((message: any) => message.content)).toEqual(['Make the title bigger', 'Done, the title is 32 pt.', 'Thanks'])
  })

  it('asks the Responses and Anthropic APIs without tools', async () => {
    const responses = await fakeModel([responsesText('Done')], [responsesText('Add a footer')])
    const first = await startHarness(env(responses, 'openai'))
    await first.ask('Add a header')
    expect(await first.until(event => event.type === 'suggestion')).toMatchObject({ text: 'Add a footer' })
    expect(responses.predictions[0].body.tools).toBeUndefined()
    expect(responses.predictions[0].body.input).toEqual([{ role: 'user', content: expect.stringContaining('User: Add a header') }])
    const anthropic = await fakeModel([anthropicText('Done')], [anthropicText('Add a footer')])
    const second = await startHarness(env(anthropic, 'anthropic'))
    await second.ask('Add a header')
    expect(await second.until(event => event.type === 'suggestion')).toMatchObject({ text: 'Add a footer' })
    expect(anthropic.predictions[0].body.tools).toBeUndefined()
    expect(anthropic.predictions[0].body.messages).toHaveLength(1)
  })

  it('suggests nothing after a failed or stopped reply', async () => {
    const failing = await fakeModel([{ status: 500, body: { error: { message: 'boom' } } }], [openaiText('Try again')])
    const first = await startHarness(env(failing))
    await first.ask('Hi')
    const stopping = await fakeModel([{ ...openaiText('Slow'), delayMs: 600 }], [openaiText('Try again')])
    const second = await startHarness(env(stopping))
    second.send({ type: 'user', text: 'Hi' })
    await pause(150)
    second.send({ type: 'stop' })
    await second.until(event => event.type === 'done')
    await pause(500)
    expect(failing.predictions).toEqual([])
    expect(stopping.predictions).toEqual([])
    expect([...first.events, ...second.events].some(event => event.type === 'suggestion')).toBe(false)
  })

  it('stays silent when the prediction fails or is empty, and the next message still works', async () => {
    const model = await fakeModel([openaiText('One'), openaiText('Two'), openaiText('Three')], [{ status: 401, body: {} }, openaiText(' \n')])
    const chat = await startHarness(env(model))
    await chat.ask('first')
    while (model.predictions.length < 1) await pause(20)
    await pause(100)
    await chat.ask('second')
    while (model.predictions.length < 2) await pause(20)
    await pause(100)
    const events = await chat.ask('third')
    expect(events.map(event => event.type)).toEqual(['assistant', 'done'])
    expect(model.predictions).toHaveLength(2)
    expect(chat.events.some(event => event.type === 'suggestion' || event.type === 'error')).toBe(false)
  })

  it('drops a prediction still in flight when the next message is sent', async () => {
    const model = await fakeModel([openaiText('One'), openaiText('Two')], [{ ...openaiText('Too late'), delayMs: 500 }])
    const chat = await startHarness(env(model))
    await chat.ask('first')
    // The slow prediction request has reached the model before the next message is sent.
    while (!model.predictions.length) await pause(20)
    await chat.ask('second')
    await pause(800)
    expect(model.predictions).toHaveLength(2)
    expect(chat.events.some(event => event.type === 'suggestion')).toBe(false)
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
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 120, output: 30, cached: 100 }, context: 150 })
    expect(model.requests[0].body.stream_options).toEqual({ include_usage: true })
    expect((await chat.ask('Again')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 50, output: 5, cached: 7 }, context: 55 })
  })

  it('reports Responses API usage', async () => {
    const model = await fakeModel([withUsage(responsesText('Hi.'), { input_tokens: 200, output_tokens: 40, input_tokens_details: { cached_tokens: 150 } })])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 200, output: 40, cached: 150 }, context: 240 })
  })

  it('counts Anthropic cache tokens as input', async () => {
    const model = await fakeModel([withUsage(anthropicText('Hi.'), { input_tokens: 10, cache_creation_input_tokens: 20, cache_read_input_tokens: 300, output_tokens: 50 })])
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 330, output: 50, cached: 300 }, context: 380 })
  })

  it('reads usage from a plain JSON body', async () => {
    const model = await fakeModel([
      { ...withUsage(openaiText('Hi.'), { prompt_tokens: 120, completion_tokens: 30 }), json: true },
      { ...withUsage(anthropicText('Hi.'), { input_tokens: 10, cache_read_input_tokens: 300, output_tokens: 50 }), json: true },
    ])
    expect((await (await deepseek(model.baseUrl)).ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 120, output: 30, cached: 0 }, context: 150 })
    const chat = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect((await chat.ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 310, output: 50, cached: 300 }, context: 360 })
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
    expect((await chat.ask('Look')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 250, output: 30, cached: 90 }, context: 170 })
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
    expect(await chat.until(event => event.type === 'done')).toEqual({ type: 'done', stopped: true, usage: { input: 100, output: 10, cached: 0 }, context: 110 })
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
      { type: 'done', stopped: false, usage: { input: 250, output: 16010, cached: 0 }, context: 110 },
    ])
    expect((await (await deepseek(model.baseUrl)).ask('Hi')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 40, output: 8, cached: 0 } })
  })

  it('still reports usage when a later round fails', async () => {
    const app = await startApp()
    const model = await fakeModel([withUsage(openaiTool('call_1', 'design_get_state', {}), { prompt_tokens: 100, completion_tokens: 10 }), { status: 500, body: {} }])
    const chat = await deepseek(model.baseUrl, { FUDEHAND_CONTROL_SOCKET: app.socketPath })
    const events = await chat.ask('Look')
    expect(events.slice(-2).map(event => event.type)).toEqual(['error', 'done'])
    expect(events.at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 100, output: 10, cached: 0 }, context: 110 })
  })
})

describe('Agent harness: context usage and /compact', () => {
  const deepseek = (baseUrl: string, extra: Record<string, string> = {}) =>
    startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: baseUrl, FUDEHAND_API_KEY: KEY, ...extra })
  /** Sends compact and waits for the turn to end. */
  async function compact(chat: Awaited<ReturnType<typeof startHarness>>) {
    const from = chat.events.length
    chat.send({ type: 'compact' })
    await chat.until(event => event.type === 'done', from)
    return chat.events.slice(from)
  }

  it('reports the context as the tokens of the last request of the reply', async () => {
    const app = await startApp()
    const model = await fakeModel([
      withUsage(openaiTool('call_1', 'design_get_state', {}), { prompt_tokens: 100, completion_tokens: 10 }),
      withUsage(openaiText('Done.'), { prompt_tokens: 150, completion_tokens: 20 }),
      openaiText('No usage.'),
    ])
    const chat = await deepseek(model.baseUrl, { FUDEHAND_CONTROL_SOCKET: app.socketPath })
    expect((await chat.ask('Look')).at(-1)).toEqual({ type: 'done', stopped: false, usage: { input: 250, output: 30, cached: 0 }, context: 170 })
    // A reply whose request reported no usage says nothing about the context.
    expect((await chat.ask('Again')).at(-1)).toEqual({ type: 'done', stopped: false })
  })

  it('replaces the history with a summary and keeps the conversation going from it', async () => {
    const model = await fakeModel([
      openaiText('The header is blue.'),
      withUsage(openaiText('The user asked for a blue header; it is done.'), { prompt_tokens: 900, completion_tokens: 40 }),
      openaiText('Blue.'),
    ])
    const chat = await deepseek(model.baseUrl)
    await chat.ask('Make the header blue')
    expect(await compact(chat)).toEqual([
      { type: 'compacted', summary: 'The user asked for a blue header; it is done.' },
      { type: 'done', stopped: false, usage: { input: 900, output: 40, cached: 0 }, context: 40 },
    ])
    // The summary request carries the whole history, the same system prompt and tools, and the instruction last.
    const request = model.requests[1].body
    expect(request.messages.slice(0, 3).map((message: any) => message.role)).toEqual(['system', 'user', 'assistant'])
    expect(request.messages[0]).toEqual(model.requests[0].body.messages[0])
    expect(request.tools).toEqual(model.requests[0].body.tools)
    expect(request.messages.at(-1).role).toBe('user')
    expect(request.messages.at(-1).content).toContain('Summarize')
    await chat.ask('Which color?')
    const after = model.requests[2].body.messages
    expect(after.map((message: any) => message.role)).toEqual(['system', 'user', 'user'])
    expect(after[1].content).toContain('The user asked for a blue header; it is done.')
    expect(after[1].content).not.toContain('Make the header blue')
    expect(after[2].content).toBe('Which color?')
  })

  it('compacts through the Responses and Anthropic APIs', async () => {
    const model = await fakeModel([
      responsesText('Hi.'), withUsage(responsesText('Summary A.'), { input_tokens: 500, output_tokens: 12 }), responsesText('Yes.'),
      anthropicText('Hi.'), withUsage(anthropicText('Summary B.'), { input_tokens: 10, cache_read_input_tokens: 600, output_tokens: 15 }), anthropicText('Yes.'),
    ])
    const openai = await startHarness({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await openai.ask('Hi')
    expect(await compact(openai)).toEqual([
      { type: 'compacted', summary: 'Summary A.' },
      { type: 'done', stopped: false, usage: { input: 500, output: 12, cached: 0 }, context: 12 },
    ])
    await openai.ask('Still there?')
    expect(model.requests[2].body.input).toHaveLength(2)
    expect(model.requests[2].body.input[0].content).toContain('Summary A.')
    const claude = await startHarness({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    await claude.ask('Hi')
    expect(await compact(claude)).toEqual([
      { type: 'compacted', summary: 'Summary B.' },
      { type: 'done', stopped: false, usage: { input: 610, output: 15, cached: 600 }, context: 15 },
    ])
    await claude.ask('Still there?')
    // The summary and the next message are both user turns, merged into one message.
    expect(model.requests[5].body.messages).toHaveLength(1)
    expect(model.requests[5].body.messages[0].content.map((block: any) => block.text).join('\n')).toContain('Summary B.')
  })

  it('keeps the history when the summary request fails, returns no text, or is stopped', async () => {
    const model = await fakeModel([
      openaiText('The header is blue.'),
      { status: 500, body: { error: { message: 'overloaded' } } },
      openaiTool('call_1', 'design_get_state', {}),
      { ...openaiText('Too late.'), delayMs: 1500 },
      openaiText('Blue.'),
    ])
    const chat = await deepseek(model.baseUrl)
    await chat.ask('Make the header blue')
    expect(await compact(chat)).toEqual([{ type: 'error', message: 'Model API error (HTTP 500): overloaded' }, { type: 'done', stopped: false }])
    // A tool call instead of a summary is not executed.
    expect(await compact(chat)).toEqual([{ type: 'error', message: 'The model returned no summary; the context was not compacted' }, { type: 'done', stopped: false }])
    chat.send({ type: 'compact' })
    await new Promise(resolve => setTimeout(resolve, 300))
    const from = chat.events.length
    chat.send({ type: 'stop' })
    expect(await chat.until(event => event.type === 'done', from)).toEqual({ type: 'done', stopped: true })
    await chat.ask('Which color?')
    expect(model.requests[4].body.messages.map((message: any) => message.content)).toEqual([
      model.requests[0].body.messages[0].content, 'Make the header blue', 'The header is blue.', 'Which color?',
    ])
  })

  it('reports that there is nothing to compact, and refuses while a reply is running', async () => {
    const model = await fakeModel([{ ...openaiText('Hi.'), delayMs: 600 }])
    const chat = await deepseek(model.baseUrl)
    expect(await compact(chat)).toEqual([{ type: 'error', message: 'There is nothing to compact yet' }, { type: 'done', stopped: false }])
    const from = chat.events.length
    chat.send({ type: 'user', text: 'Hi' })
    chat.send({ type: 'compact' })
    expect(await chat.until(event => event.type === 'error', from)).toEqual({ type: 'error', message: 'The previous reply has not finished yet' })
    await chat.until(event => event.type === 'done', from)
    expect(model.requests).toHaveLength(1)
  })

  it('loads a compacted conversation starting from its summary', async () => {
    const model = await fakeModel([openaiText('Blue.')])
    const chat = await deepseek(model.baseUrl)
    chat.send({ type: 'load', messages: [{ role: 'summary', text: 'The header is blue.' }, { role: 'user', text: 'Thanks' }, { role: 'assistant', text: 'Welcome.' }] })
    await chat.ask('Which color?')
    const messages = model.requests[0].body.messages
    expect(messages.map((message: any) => message.role)).toEqual(['system', 'user', 'user', 'assistant', 'user'])
    expect(messages[1].content).toContain('The header is blue.')
    expect(messages[1].content).not.toBe('The header is blue.')
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
    const model = await fakeModel([{ body: { object: 'list', data: [{ id: 'deepseek-chat', context_window: 1048576 }, { id: 'deepseek-reasoner' }, { id: 'deepseek-chat' }] } }])
    const result = await listModels({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: `${model.baseUrl}/`, FUDEHAND_API_KEY: KEY })
    expect(result.code).toBe(0)
    // A model's context window is passed on when the list reports one.
    expect(result.event).toEqual({ type: 'models', models: ['deepseek-chat', 'deepseek-reasoner'], default: 'deepseek-chat', windows: { 'deepseek-chat': 1048576 } })
    expect(model.requests[0].url).toBe('/models')
    expect(model.requests[0].headers.authorization).toBe(`Bearer ${KEY}`)
  })

  it('reads /models for the OpenAI Responses provider too', async () => {
    const model = await fakeModel([{ body: { data: [{ id: 'gpt-5.3-codex' }, { id: 'gpt-6.1-terra' }, { id: 'text-embedding-3-small' }] } }])
    const result = await listModels({ FUDEHAND_PROVIDER: 'openai', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    // OpenAI's list reports no context window; the documented ones of its current families are filled in.
    expect(result.event).toEqual({
      type: 'models', models: ['gpt-5.3-codex', 'gpt-6.1-terra', 'text-embedding-3-small'], default: 'gpt-5.3-codex',
      windows: { 'gpt-5.3-codex': 400000, 'gpt-6.1-terra': 1050000 },
    })
    expect(model.requests[0].url).toBe('/models')
  })

  it('reads /v1/models from Anthropic with its own auth headers', async () => {
    const model = await fakeModel([{ body: { data: [{ id: 'claude-opus-5-5', type: 'model', max_input_tokens: 1000000 }, { id: 'claude-sonnet-5-5', type: 'model', max_input_tokens: null }], has_more: false } }])
    const result = await listModels({ FUDEHAND_PROVIDER: 'anthropic', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
    expect(result.event).toEqual({ type: 'models', models: ['claude-opus-5-5', 'claude-sonnet-5-5'], default: 'claude-sonnet-5-5', windows: { 'claude-opus-5-5': 1000000 } })
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

describe('Agent harness: asking the user a question', () => {
  const QUESTION = { question: 'How many entries?', detail: 'It decides the icon size.', options: [{ label: '3 entries', description: 'Roomy' }, { label: '4 entries' }] }
  const deepseek = (model: { baseUrl: string }, extra: Record<string, string> = {}) =>
    startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY, ...extra })

  it('offers ask_user to every provider, and keeps it out of the MCP tools', async () => {
    const { tools } = await import('../scripts/fudehand-tools.mjs')
    expect(tools.map((tool: { name: string }) => tool.name)).not.toContain('ask_user')
    for (const [provider, reply] of [['deepseek', openaiText('Hi')], ['openai', responsesText('Hi')], ['anthropic', anthropicText('Hi')]] as const) {
      const model = await fakeModel([reply])
      const chat = await startHarness({ FUDEHAND_PROVIDER: provider, FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
      await chat.ask('Hello')
      const names = model.requests[0].body.tools.map((tool: any) => tool.name ?? tool.function.name)
      expect(names).toContain('ask_user')
    }
  })

  it('pauses the reply on a question and hands the answer to the model as the tool result', async () => {
    for (const [provider, replies] of [
      ['deepseek', [openaiTool('call_q', 'ask_user', QUESTION), openaiText('Added 3 entries.')]],
      ['openai', [responsesTool('call_q', 'ask_user', QUESTION), responsesText('Added 3 entries.')]],
      ['anthropic', [anthropicTool('call_q', 'ask_user', QUESTION), anthropicText('Added 3 entries.')]],
    ] as const) {
      const model = await fakeModel([...replies])
      const chat = await startHarness({ FUDEHAND_PROVIDER: provider, FUDEHAND_BASE_URL: model.baseUrl, FUDEHAND_API_KEY: KEY })
      chat.send({ type: 'user', text: 'Add a bottom navigation' })
      const question = await chat.until(event => event.type === 'question')
      expect(question).toEqual({ type: 'question', id: 'call_q', ...QUESTION })
      // Nothing happens until the user answers.
      await new Promise(resolve => setTimeout(resolve, 150))
      expect(model.requests).toHaveLength(1)
      expect(chat.events.some(event => event.type === 'done')).toBe(false)
      chat.send({ type: 'answer', id: 'call_q', question: QUESTION.question, text: '3 entries' })
      await chat.until(event => event.type === 'done')
      expect(chat.events.filter(event => event.type === 'tool_call' || event.type === 'tool_result')).toEqual([])
      expect(chat.events.at(-1)).toMatchObject({ type: 'done', stopped: false })
      expect(JSON.stringify(model.requests[1].body)).toContain('The user answered: 3 entries')
    }
  })

  it('tells the model to decide itself when the question is skipped', async () => {
    const model = await fakeModel([openaiTool('call_q', 'ask_user', QUESTION), openaiText('Went with 3.')])
    const chat = await deepseek(model)
    chat.send({ type: 'user', text: 'Add a bottom navigation' })
    await chat.until(event => event.type === 'question')
    chat.send({ type: 'answer', id: 'call_q', question: QUESTION.question, skipped: true })
    await chat.until(event => event.type === 'done')
    expect(model.requests[1].body.messages.at(-1)).toMatchObject({ role: 'tool', tool_call_id: 'call_q', content: 'The user skipped the question: decide yourself and carry on.' })
  })

  it('cancels the question on a stop and runs no later tool call', async () => {
    const app = await startApp()
    const both = { body: { choices: [{ message: { role: 'assistant', content: null, tool_calls: [
      { id: 'call_q', type: 'function', function: { name: 'ask_user', arguments: JSON.stringify(QUESTION) } },
      { id: 'call_s', type: 'function', function: { name: 'design_get_state', arguments: '{}' } },
    ] } }] } }
    const model = await fakeModel([both, openaiText('Next turn.')])
    const chat = await deepseek(model, { FUDEHAND_CONTROL_SOCKET: app.socketPath })
    chat.send({ type: 'user', text: 'Add a bottom navigation' })
    await chat.until(event => event.type === 'question')
    chat.send({ type: 'stop' })
    expect(await chat.until(event => event.type === 'done')).toMatchObject({ stopped: true })
    expect(app.received).toEqual([])
    expect(model.requests).toHaveLength(1)
    // A late answer to the cancelled question does not resume the stopped turn; the history stays valid for the next message.
    chat.send({ type: 'answer', id: 'call_q', question: QUESTION.question, text: '3 entries' })
    await new Promise(resolve => setTimeout(resolve, 150))
    expect(model.requests).toHaveLength(1)
    await chat.ask('Never mind')
    const messages = model.requests[1].body.messages
    expect(messages.filter((message: any) => message.role === 'tool').map((message: any) => message.tool_call_id)).toEqual(['call_q', 'call_s'])
  })

  it('returns an error to the model instead of showing a malformed or second question', async () => {
    const calls = [
      { ...QUESTION, options: [{ label: 'Only one' }] },
      { ...QUESTION, options: Array.from({ length: 5 }, (_, index) => ({ label: `Option ${index}` })) },
      { ...QUESTION, question: '  ' },
      { ...QUESTION, options: [{ label: 'A' }, { description: 'No label' }] },
    ]
    const model = await fakeModel([...calls.map((args, index) => openaiTool(`call_${index}`, 'ask_user', args)), openaiText('I will decide myself.')])
    const chat = await deepseek(model)
    const events = await chat.ask('Add a bottom navigation')
    expect(events.map(event => event.type)).toEqual(['assistant', 'done'])
    for (const [index, request] of model.requests.slice(1).entries()) {
      expect(request.body.messages.at(-1)).toMatchObject({ role: 'tool', tool_call_id: `call_${index}` })
      expect(request.body.messages.at(-1).content).toMatch(/^ask_user: /)
    }

    const twice = { body: { choices: [{ message: { role: 'assistant', content: null, tool_calls: ['call_a', 'call_b'].map(id => (
      { id, type: 'function', function: { name: 'ask_user', arguments: JSON.stringify(QUESTION) } })) } }] } }
    const second = await fakeModel([twice, openaiText('Done.')])
    const other = await deepseek(second)
    other.send({ type: 'user', text: 'Add a bottom navigation' })
    await other.until(event => event.type === 'question')
    other.send({ type: 'answer', id: 'call_a', question: QUESTION.question, text: '4 entries' })
    await other.until(event => event.type === 'done')
    expect(other.events.filter(event => event.type === 'question')).toHaveLength(1)
    expect(second.requests[1].body.messages.at(-1).content).toMatch(/^ask_user: .*one question/)
  })

  it('starts a new turn from an answer when the question is no longer waiting', async () => {
    const model = await fakeModel([openaiText('Added 3 entries.'), openaiText('Went with my pick.')])
    const chat = await deepseek(model)
    chat.send({ type: 'load', messages: [{ role: 'user', text: 'Add a bottom navigation' }] })
    chat.send({ type: 'answer', id: 'call_old', question: QUESTION.question, text: '3 entries' })
    await chat.until(event => event.type === 'done')
    expect(model.requests[0].body.messages.slice(1)).toEqual([
      { role: 'user', content: 'Add a bottom navigation' },
      { role: 'user', content: 'You asked the user: How many entries?\nThe user answered: 3 entries' },
    ])
    const from = chat.events.length
    chat.send({ type: 'answer', id: 'call_old', question: QUESTION.question, skipped: true })
    await chat.until(event => event.type === 'done', from)
    expect(model.requests[1].body.messages.at(-1).content).toBe('You asked the user: How many entries?\nThe user skipped the question: decide yourself and carry on.')
  })

  it('ignores an answer that matches no waiting question while a reply is running', async () => {
    const model = await fakeModel([{ ...openaiText('Working on it.'), delayMs: 300 }])
    const chat = await deepseek(model)
    chat.send({ type: 'user', text: 'Add a bottom navigation' })
    chat.send({ type: 'answer', id: 'call_stale', question: QUESTION.question, text: '3 entries' })
    await chat.until(event => event.type === 'done')
    await new Promise(resolve => setTimeout(resolve, 100))
    expect(chat.events.filter(event => event.type === 'error')).toEqual([])
    expect(model.requests).toHaveLength(1)
  })
})

describe('Agent harness: plan and goal modes', () => {
  const deepseek = (baseUrl: string, socketPath: string) =>
    startHarness({ FUDEHAND_PROVIDER: 'deepseek', FUDEHAND_BASE_URL: baseUrl, FUDEHAND_API_KEY: KEY, FUDEHAND_CONTROL_SOCKET: socketPath })
  const toolNames = (request: Captured) => request.body.tools.map((tool: any) => tool.function.name)

  it('offers only reading tools in plan mode and refuses an edit the model asks for anyway', async () => {
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const model = await fakeModel([
      openaiTool('call_1', 'design_get_state', {}),
      openaiTool('call_2', 'design_delete_nodes', { ids: ['home'] }),
      openaiText('1. Delete the Demo page frame.'),
      openaiText('Deleted.'),
    ])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const events = await chat.ask('Remove the demo page', { mode: 'plan' })
    expect(toolNames(model.requests[0])).toEqual(['design_get_state', 'design_get_document', 'design_get_node', 'design_search_icons', 'design_snapshot', 'ask_user'])
    expect(model.requests[0].body.messages[0].content).toMatch(/Plan mode is on/)
    expect(app.received.map(request => request.command)).toEqual(['get_state'])
    expect(events.find(event => event.type === 'tool_result' && event.name === 'design_delete_nodes'))
      .toMatchObject({ ok: false, text: 'Plan mode: the design document cannot be changed until the user confirms the plan.' })
    expect(events.at(-2)).toEqual({ type: 'assistant', text: '1. Delete the Demo page frame.' })
    // What comes next is confirming the plan, so no next message is predicted.
    await pause(300)
    expect(model.predictions).toEqual([])

    // Confirming is an ordinary message: every tool is back and the plan is in the history.
    await chat.ask('Carry out the plan.')
    expect(toolNames(model.requests[3])).toContain('design_delete_nodes')
    expect(model.requests[3].body.messages[0].content).not.toMatch(/Plan mode is on/)
    expect(model.requests[3].body.messages.at(-2).content).toBe('1. Delete the Demo page frame.')
  })

  it('keeps plan mode when an answer reaches a harness that was started anew', async () => {
    const app = await startApp()
    const model = await fakeModel([openaiText('1. Use three entries.')])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    chat.send({ type: 'answer', id: 'call_before_restart', question: 'How many entries?', text: '3 entries', mode: 'plan' })
    await chat.until(event => event.type === 'done')
    expect(toolNames(model.requests[0])).not.toContain('design_create_node')
    expect(model.requests[0].body.messages[0].content).toMatch(/Plan mode is on/)
  })

  it('keeps working in goal mode until the model reports the goal done', async () => {
    const app = await startApp()
    const model = await fakeModel([
      openaiTool('call_1', 'design_get_state', {}),
      openaiText('I looked at the document.'),
      openaiTool('call_2', 'goal_done', { summary: 'The page is ready.' }),
      openaiText('Hello.'),
    ], [openaiText('Add a footer')])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const events = await chat.ask('Get the page ready', { mode: 'goal' })
    expect(events.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'assistant', 'done'])
    expect(events.at(-2)).toEqual({ type: 'assistant', text: 'The page is ready.' })
    expect(events.at(-1)).toMatchObject({ stopped: false })
    expect(model.requests).toHaveLength(3)
    expect(toolNames(model.requests[0])).toContain('goal_done')
    expect(model.requests[0].body.messages[0].content).toMatch(/Goal mode is on/)
    // A reply without tool calls did not end the goal: the model was told to go on.
    expect(model.requests[2].body.messages.at(-1)).toMatchObject({ role: 'user', content: expect.stringMatching(/not been marked as done/) })
    expect(app.received.map(request => request.command)).toEqual(['get_state'])

    // The prediction that follows reads the summary as the reply, and not the reminder as something the user said.
    await chat.until(event => event.type === 'suggestion')
    expect(model.predictions[0].body.messages[1].content).toMatch(/Assistant: The page is ready\.$/)
    expect(model.predictions[0].body.messages[1].content).not.toMatch(/marked as done/)

    // Afterwards goal_done is gone, and so is the reminder's request to call it.
    await chat.ask('Hi')
    expect(toolNames(model.requests[3])).not.toContain('goal_done')
    const later = model.requests[3].body.messages
    expect(later.some((message: any) => /goal_done/.test(String(message.content)))).toBe(false)
    expect(later.at(-2)).toMatchObject({ role: 'assistant', content: 'The page is ready.' })
  })

  it('keeps a goal going through progress notes without tool calls', async () => {
    const app = await startApp()
    const model = await fakeModel([
      openaiText('Next I will add the header.'),
      openaiText('Now the footer.'),
      openaiTool('call_1', 'design_get_state', {}),
      openaiTool('call_2', 'goal_done', { summary: 'Done.' }),
    ])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const events = await chat.ask('Build the page', { mode: 'goal' })
    expect(events.at(-2)).toEqual({ type: 'assistant', text: 'Done.' })
    expect(model.requests).toHaveLength(4)
    expect(model.requests[0].body.messages[0].content).toMatch(/progress note/)
  })

  it('ends a goal the model stops working on without reporting it done', async () => {
    const app = await startApp()
    const model = await fakeModel([
      openaiText('What colour should it be?'), openaiText('I need the colour.'), openaiText('Still need it.'), openaiText('Cannot go on.'),
      openaiText('Unused'),
    ])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const events = await chat.ask('Make it nicer', { mode: 'goal' })
    expect(events.map(event => event.type)).toEqual(['assistant', 'assistant', 'assistant', 'assistant', 'done'])
    expect(model.requests).toHaveLength(4)
  })

  it('lets a goal run past the tool-call rounds of an ordinary reply', async () => {
    const app = await startApp()
    const model = await fakeModel([
      ...Array.from({ length: 20 }, (_, index) => openaiTool(`call_${index}`, 'design_get_state', {})),
      openaiTool('call_done', 'goal_done', { summary: 'Checked.' }),
    ])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const events = await chat.ask('Keep checking', { mode: 'goal' })
    expect(events.some(event => event.type === 'error')).toBe(false)
    expect(events.at(-2)).toEqual({ type: 'assistant', text: 'Checked.' })
    expect(app.received).toHaveLength(20)
  })

  it('runs no tool the model called after reporting the goal done', async () => {
    const app = await startApp(() => ({ ok: true, result: { deleted: ['home'] } }))
    const calls = [['call_1', 'design_get_state', {}], ['call_2', 'goal_done', { summary: 'Checked.' }], ['call_3', 'design_delete_nodes', { ids: ['home'] }]]
      .map(([id, name, args]) => ({ id, type: 'function', function: { name, arguments: JSON.stringify(args) } }))
    const model = await fakeModel([{ body: { choices: [{ message: { role: 'assistant', content: null, tool_calls: calls } }] } }, openaiText('Hello.')])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const events = await chat.ask('Check the page', { mode: 'goal' })
    expect(events.map(event => event.type)).toEqual(['tool_call', 'tool_result', 'assistant', 'done'])
    expect(app.received.map(request => request.command)).toEqual(['get_state'])
    // The skipped call still has a result in the history, as the APIs require.
    await chat.ask('Hi')
    expect(model.requests[1].body.messages.find((message: any) => message.tool_call_id === 'call_3').content).toMatch(/not executed/)
  })

  it('asks for the summary when the model reports a goal done without one', async () => {
    const app = await startApp()
    const model = await fakeModel([openaiTool('call_1', 'goal_done', { summary: '  ' }), openaiTool('call_2', 'goal_done', { summary: 'The page is ready.' })])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const events = await chat.ask('Get the page ready', { mode: 'goal' })
    expect(events.map(event => event.type)).toEqual(['assistant', 'done'])
    expect(events[0].text).toBe('The page is ready.')
    expect(model.requests[1].body.messages.at(-1)).toMatchObject({ role: 'tool', tool_call_id: 'call_1', content: expect.stringMatching(/summary/) })
  })

  it('runs nothing further once a goal is stopped', async () => {
    const app = await startApp()
    const model = await fakeModel([
      openaiTool('call_1', 'design_get_state', {}),
      { ...openaiTool('call_2', 'design_get_state', {}), delayMs: 800 },
      openaiTool('call_3', 'design_get_state', {}),
    ])
    const chat = await deepseek(model.baseUrl, app.socketPath)
    const from = chat.events.length
    chat.send({ type: 'user', text: 'Keep checking', mode: 'goal' })
    await chat.until(event => event.type === 'tool_result', from)
    chat.send({ type: 'stop' })
    const done = await chat.until(event => event.type === 'done', from)
    expect(done.stopped).toBe(true)
    await new Promise(resolve => setTimeout(resolve, 1000))
    expect(app.received).toHaveLength(1)
    expect(model.requests).toHaveLength(2)
  })
})
