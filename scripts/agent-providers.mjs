/**
 * Model provider adapters. The conversation history uses a neutral format and is converted to each API's format on every request:
 *   { role: 'user', text }
 *   { role: 'assistant', text, toolCalls: [{ id, name, args }], blocks? }
 *   { role: 'tool', id, name, text, isError, images?: [{ data (base64), mimeType }] }
 * When tool arguments cannot be parsed, the item in toolCalls carries an error field and the harness does not execute it.
 * blocks holds the provider's own content blocks for the turn (Anthropic only), sent back unchanged.
 * images is only set for a provider whose `images` flag is true; the Chat Completions API has no way to carry an image in a tool result.
 */

export const providerDefaults = {
  deepseek: { kind: 'openai', baseUrl: 'https://api.deepseek.com', model: 'deepseek-chat' },
  // Codex-series models only support the Responses API.
  openai: { kind: 'responses', baseUrl: 'https://api.openai.com/v1', model: 'gpt-5.3-codex' },
  anthropic: { kind: 'anthropic', baseUrl: 'https://api.anthropic.com', model: 'claude-sonnet-5-5' },
}

/** Sends the request and turns HTTP statuses and network errors into the messages shown in the chat panel. */
async function open(url, init, signal) {
  let response
  try {
    response = await fetch(url, { ...init, signal })
  } catch (error) {
    if (signal.aborted) throw error
    throw new Error(`Could not connect to the model API: ${error.cause?.message ?? error.message}`)
  }
  if (response.ok) return response
  const body = await response.json().catch(() => null)
  if (response.status === 401 || response.status === 403) throw new Error('Invalid API key or insufficient permissions')
  if (response.status === 402 || response.status === 429) throw new Error('Quota exceeded or too many requests')
  const detail = body?.error?.message ?? body?.message ?? response.statusText
  throw new Error(`Model API error (HTTP ${response.status}): ${String(detail).slice(0, 300)}`)
}

async function json(response) {
  const body = await response.json().catch(() => null)
  if (!body || typeof body !== 'object') throw new Error('The model API returned an unparseable response')
  return body
}

async function request(url, init, signal) {
  return json(await open(url, init, signal))
}

/** Yields the JSON payload of each server-sent event; an error event ends the reply with the provider's message. */
async function* events(response, signal) {
  const decoder = new TextDecoder()
  let buffer = ''
  try {
    // The empty chunk at the end closes a last event that has no blank line after it.
    const chunks = (async function* () { yield* response.body; yield null })()
    for await (const chunk of chunks) {
      buffer += chunk ? decoder.decode(chunk, { stream: true }) : '\n\n'
      for (let end; (end = buffer.search(/\r?\n\r?\n/)) >= 0;) {
        const data = buffer.slice(0, end).split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n')
        buffer = buffer.slice(end).replace(/^\r?\n\r?\n/, '')
        if (!data || data === '[DONE]') continue
        let event
        try { event = JSON.parse(data) } catch { continue }
        const failure = event.error ?? event.response?.error ?? (event.type === 'error' ? event : null)
        if (failure) throw new Error(`Model API error: ${String(failure.message ?? JSON.stringify(failure)).slice(0, 300)}`)
        yield event
      }
    }
  } catch (error) {
    if (signal.aborted || error.message.startsWith('Model API error')) throw error
    throw new Error(`The connection to the model API was interrupted: ${error.cause?.message ?? error.message}`)
  }
}

/**
 * Requests a streamed turn. `assemble` consumes the events, reporting text through onText as it arrives, and returns the same body
 * the non-streaming API would; an endpoint that ignores `stream` and answers with plain JSON is read as that body directly.
 */
async function streamed(url, init, signal, assemble) {
  const response = await open(url, init, signal)
  if (!response.headers.get('content-type')?.includes('text/event-stream')) return json(response)
  return assemble(events(response, signal))
}

function openaiMessages(system, history) {
  return [{ role: 'system', content: system }, ...history.map(entry => {
    if (entry.role === 'user') return { role: 'user', content: entry.text }
    if (entry.role === 'tool') return { role: 'tool', tool_call_id: entry.id, content: entry.text }
    const message = { role: 'assistant', content: entry.text || null }
    if (entry.toolCalls.length) {
      message.tool_calls = entry.toolCalls.map(call => ({ id: call.id, type: 'function', function: { name: call.name, arguments: JSON.stringify(call.args) } }))
    }
    return message
  })]
}

function responsesInput(history) {
  return history.flatMap(entry => {
    if (entry.role === 'user') return [{ role: 'user', content: entry.text }]
    if (entry.role === 'tool') {
      const output = entry.images?.length ? [
        ...entry.images.map(image => ({ type: 'input_image', image_url: `data:${image.mimeType};base64,${image.data}` })),
        { type: 'input_text', text: entry.text },
      ] : entry.text
      return [{ type: 'function_call_output', call_id: entry.id, output }]
    }
    return [
      ...(entry.text ? [{ role: 'assistant', content: entry.text }] : []),
      ...entry.toolCalls.map(call => ({ type: 'function_call', call_id: call.id, name: call.name, arguments: JSON.stringify(call.args) })),
    ]
  })
}

function anthropicMessages(history) {
  const messages = []
  // Anthropic requires user and assistant to alternate: tool results and the user message that follows are merged into the same user message.
  const push = (role, blocks) => {
    const last = messages.at(-1)
    if (last?.role === role) last.content.push(...blocks)
    else messages.push({ role, content: blocks })
  }
  for (const entry of history) {
    if (entry.role === 'user') push('user', [{ type: 'text', text: entry.text }])
    else if (entry.role === 'tool') {
      const content = entry.images?.length ? [
        ...entry.images.map(image => ({ type: 'image', source: { type: 'base64', media_type: image.mimeType, data: image.data } })),
        { type: 'text', text: entry.text },
      ] : entry.text
      push('user', [{ type: 'tool_result', tool_use_id: entry.id, content, ...(entry.isError ? { is_error: true } : {}) }])
    }
    // Thinking blocks are only valid when the turn is sent back exactly as the model produced it.
    else push('assistant', entry.blocks ?? [
      ...(entry.text ? [{ type: 'text', text: entry.text }] : []),
      ...entry.toolCalls.map(call => ({ type: 'tool_use', id: call.id, name: call.name, input: call.args })),
    ])
  }
  return messages
}

const truncated = 'The model reply was cut off by the length limit; stopped this reply'
// The stream closed without the event that ends a reply; what arrived may be half a sentence or half a tool call.
const incomplete = 'The model reply ended before it was complete; stopped this reply'

/** The error for a request that completed but whose reply cannot be used; it carries the request's usage, which was consumed all the same. */
function unusable(message, usage) {
  return Object.assign(new Error(message), { usage })
}

function functionCall(id, name, raw) {
  try {
    const args = raw ? JSON.parse(raw) : {}
    if (args && typeof args === 'object' && !Array.isArray(args)) return { id, name, args }
  } catch {}
  return { id, name, args: {}, error: 'Tool arguments are not valid JSON' }
}

/** The token counts of one request as { input, output, cached }: input includes the cached tokens. Undefined when the API reported none or they are not counts. */
function tokenUsage(input, output, cached) {
  const usage = { input, output, cached: cached ?? 0 }
  return Object.values(usage).every(count => Number.isInteger(count) && count >= 0) ? usage : undefined
}

// OpenAI's model list reports no context window; these are the documented ones, by model id prefix.
const openaiWindows = [['gpt-6', 1_050_000], ['gpt-5.3-codex', 400_000]]

/**
 * Reads the provider's model list, returning { models: [id], default, windows: { id: tokens } }; used for the model menus and the
 * context ring. windows holds the context window of the models for which one is known: DeepSeek reports `context_window` and
 * Anthropic `max_input_tokens`.
 */
export async function listModels({ provider, baseUrl, apiKey }, signal) {
  const defaults = providerDefaults[provider]
  if (!defaults) throw new Error(`Unknown model provider: ${provider}`)
  const base = (baseUrl || defaults.baseUrl).replace(/\/+$/, '')
  const body = defaults.kind === 'anthropic'
    ? await request(`${base}/v1/models?limit=1000`, { headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' } }, signal)
    : await request(`${base}/models`, { headers: { authorization: `Bearer ${apiKey}` } }, signal)
  const items = (Array.isArray(body.data) ? body.data : []).filter(item => typeof item?.id === 'string' && item.id)
  const windows = {}
  for (const item of items) {
    const known = provider === 'openai' ? openaiWindows.find(([prefix]) => item.id.startsWith(prefix))?.[1] : undefined
    const window = item.context_window ?? item.max_input_tokens ?? known
    if (Number.isInteger(window) && window > 0) windows[item.id] = window
  }
  return { models: [...new Set(items.map(item => item.id))], default: defaults.model, windows }
}

/**
 * Returns { model, images, turn(system, history, tools, signal, onText) → { text, toolCalls, usage? } }; images says whether tool results
 * can carry images, onText receives the reply text as it streams in, and usage is the request's token counts (see tokenUsage).
 * With no tools the request leaves `tools` out, since the Chat Completions API rejects an empty list.
 */
export function createProvider({ provider, model, baseUrl, apiKey }) {
  const defaults = providerDefaults[provider]
  if (!defaults) throw new Error(`Unknown model provider: ${provider}`)
  const base = (baseUrl || defaults.baseUrl).replace(/\/+$/, '')
  const name = model || defaults.model
  if (defaults.kind === 'openai') {
    return {
      model: name,
      images: false,
      async turn(system, history, tools, signal, onText) {
        const body = await streamed(`${base}/chat/completions`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
          body: JSON.stringify({
            model: name, messages: openaiMessages(system, history), stream: true, stream_options: { include_usage: true },
            ...(tools.length ? { tools: tools.map(tool => ({ type: 'function', function: { name: tool.name, description: tool.description, parameters: tool.inputSchema } })) } : {}),
          }),
        }, signal, async stream => {
          const message = { content: '', tool_calls: [] }
          let finish_reason
          let usage
          for await (const event of stream) {
            // The usage arrives in a last chunk that has no choices.
            if (event.usage) usage = event.usage
            const choice = event.choices?.[0] ?? {}
            if (choice.finish_reason) finish_reason = choice.finish_reason
            if (choice.delta?.content) { message.content += choice.delta.content; onText(choice.delta.content) }
            for (const part of choice.delta?.tool_calls ?? []) {
              // Some compatible servers send each call whole and without an index; a new id then starts a new call.
              const last = message.tool_calls.length - 1
              const slot = part.index ?? (part.id && part.id !== message.tool_calls[last]?.id ? last + 1 : Math.max(last, 0))
              const call = message.tool_calls[slot] ??= { id: '', function: { name: '', arguments: '' } }
              if (part.id) call.id = part.id
              if (part.function?.name) call.function.name = part.function.name
              call.function.arguments += part.function?.arguments ?? ''
            }
          }
          if (!finish_reason) throw new Error(incomplete)
          return { choices: [{ finish_reason, message: { ...message, tool_calls: message.tool_calls.filter(Boolean) } }], usage }
        })
        const choice = body.choices?.[0] ?? {}
        // DeepSeek reports cache hits at the top level, OpenAI under prompt_tokens_details.
        const usage = tokenUsage(body.usage?.prompt_tokens, body.usage?.completion_tokens, body.usage?.prompt_cache_hit_tokens ?? body.usage?.prompt_tokens_details?.cached_tokens)
        if (choice.finish_reason === 'length') throw unusable(truncated, usage)
        const message = choice.message ?? {}
        return {
          text: message.content ?? '',
          toolCalls: (message.tool_calls ?? []).map(call => functionCall(call.id, call.function?.name, call.function?.arguments)),
          usage,
        }
      },
    }
  }
  if (defaults.kind === 'responses') {
    return {
      model: name,
      images: true,
      async turn(system, history, tools, signal, onText) {
        const body = await streamed(`${base}/responses`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
          body: JSON.stringify({
            model: name, instructions: system, input: responsesInput(history), store: false, stream: true,
            ...(tools.length ? { tools: tools.map(tool => ({ type: 'function', name: tool.name, description: tool.description, parameters: tool.inputSchema, strict: false })) } : {}),
          }),
        }, signal, async stream => {
          // The closing event carries the whole response, so only the text deltas are read on the way.
          let response
          for await (const event of stream) {
            if (event.type === 'response.output_text.delta' && event.delta) onText(event.delta)
            else if (event.type === 'response.completed' || event.type === 'response.incomplete') response = event.response
          }
          if (!response) throw new Error(incomplete)
          return response
        })
        const usage = tokenUsage(body.usage?.input_tokens, body.usage?.output_tokens, body.usage?.input_tokens_details?.cached_tokens)
        if (body.status === 'incomplete') throw unusable(truncated, usage)
        const output = body.output ?? []
        return {
          text: output.filter(item => item.type === 'message').flatMap(item => item.content ?? [])
            .filter(part => part.type === 'output_text').map(part => part.text).join(''),
          toolCalls: output.filter(item => item.type === 'function_call').map(item => functionCall(item.call_id, item.name, item.arguments)),
          usage,
        }
      },
    }
  }
  return {
    model: name,
    images: true,
    async turn(system, history, tools, signal, onText) {
      // Tool calls whose streamed arguments did not form valid JSON; they are reported to the model instead of executed.
      const malformed = new Set()
      const body = await streamed(`${base}/v1/messages`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
        body: JSON.stringify({
          model: name, max_tokens: 16000, system, messages: anthropicMessages(history), stream: true,
          ...(tools.length ? { tools: tools.map(tool => ({ name: tool.name, description: tool.description, input_schema: tool.inputSchema })) } : {}),
        }),
      }, signal, async stream => {
        const content = []
        const partial = []
        let stop_reason
        // message_start carries the input counts and message_delta the output count.
        let usage
        for await (const event of stream) {
          const block = content[event.index]
          const delta = event.delta ?? {}
          if (event.type === 'content_block_start') { content[event.index] = { ...event.content_block }; partial[event.index] = '' }
          else if (event.type === 'message_start') usage = event.message?.usage
          else if (event.type === 'message_delta') { stop_reason = delta.stop_reason ?? stop_reason; usage = { ...usage, ...event.usage } }
          else if (event.type === 'content_block_stop' && block?.type === 'tool_use') {
            try { block.input = partial[event.index] ? JSON.parse(partial[event.index]) : {} } catch { malformed.add(block.id) }
          } else if (event.type !== 'content_block_delta' || !block) continue
          else if (delta.type === 'text_delta') { block.text += delta.text; onText(delta.text) }
          else if (delta.type === 'input_json_delta') partial[event.index] += delta.partial_json
          else if (delta.type === 'thinking_delta') block.thinking += delta.thinking
          else if (delta.type === 'signature_delta') block.signature = delta.signature
        }
        if (!stop_reason) throw new Error(incomplete)
        return { content: content.filter(Boolean), stop_reason, usage }
      })
      // Anthropic counts cached input apart from input_tokens.
      const { input_tokens, output_tokens, cache_creation_input_tokens = 0, cache_read_input_tokens = 0 } = body.usage ?? {}
      const usage = tokenUsage(input_tokens + cache_creation_input_tokens + cache_read_input_tokens, output_tokens, cache_read_input_tokens)
      if (body.stop_reason === 'max_tokens') throw unusable(truncated, usage)
      if (body.stop_reason === 'refusal') throw unusable('The model declined this request; stopped this reply', usage)
      if (body.stop_reason === 'pause_turn') throw unusable('The model paused before finishing; stopped this reply', usage)
      const blocks = body.content ?? []
      return {
        blocks,
        usage,
        text: blocks.filter(block => block.type === 'text').map(block => block.text).join(''),
        toolCalls: blocks.filter(block => block.type === 'tool_use').map(block => ({
          id: block.id, name: block.name, args: block.input ?? {}, ...(malformed.has(block.id) ? { error: 'Tool arguments are not valid JSON' } : {}),
        })),
      }
    },
  }
}
