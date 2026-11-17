/**
 * Model provider adapters. The conversation history uses a neutral format and is converted to each API's format on every request:
 *   { role: 'user', text }
 *   { role: 'assistant', text, toolCalls: [{ id, name, args }] }
 *   { role: 'tool', id, name, text, isError }
 * When tool arguments cannot be parsed, the item in toolCalls carries an error field and the harness does not execute it.
 */

export const providerDefaults = {
  deepseek: { kind: 'openai', baseUrl: 'https://api.deepseek.com', model: 'deepseek-chat' },
  // Codex-series models only support the Responses API.
  openai: { kind: 'responses', baseUrl: 'https://api.openai.com/v1', model: 'gpt-5-codex' },
  anthropic: { kind: 'anthropic', baseUrl: 'https://api.anthropic.com', model: 'claude-sonnet-5-5' },
}

/** Turns HTTP statuses and network errors into the messages shown in the chat panel. */
async function request(url, init, signal) {
  let response
  try {
    response = await fetch(url, { ...init, signal })
  } catch (error) {
    if (signal.aborted) throw error
    throw new Error(`Could not connect to the model API: ${error.cause?.message ?? error.message}`)
  }
  const body = await response.json().catch(() => null)
  if (response.ok) {
    if (!body || typeof body !== 'object') throw new Error('The model API returned an unparseable response')
    return body
  }
  if (response.status === 401 || response.status === 403) throw new Error('Invalid API key or insufficient permissions')
  if (response.status === 402 || response.status === 429) throw new Error('Quota exceeded or too many requests')
  const detail = body?.error?.message ?? body?.message ?? response.statusText
  throw new Error(`Model API error (HTTP ${response.status}): ${String(detail).slice(0, 300)}`)
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
    if (entry.role === 'tool') return [{ type: 'function_call_output', call_id: entry.id, output: entry.text }]
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
    else if (entry.role === 'tool') push('user', [{ type: 'tool_result', tool_use_id: entry.id, content: entry.text, ...(entry.isError ? { is_error: true } : {}) }])
    else push('assistant', [
      ...(entry.text ? [{ type: 'text', text: entry.text }] : []),
      ...entry.toolCalls.map(call => ({ type: 'tool_use', id: call.id, name: call.name, input: call.args })),
    ])
  }
  return messages
}

const truncated = 'The model reply was cut off by the length limit; stopped this reply'

function functionCall(id, name, raw) {
  try {
    const args = raw ? JSON.parse(raw) : {}
    if (args && typeof args === 'object' && !Array.isArray(args)) return { id, name, args }
  } catch {}
  return { id, name, args: {}, error: 'Tool arguments are not valid JSON' }
}

/** Reads the provider's model list, returning { models: [id], default }; used for the dropdown menu in the settings panel. */
export async function listModels({ provider, baseUrl, apiKey }, signal) {
  const defaults = providerDefaults[provider]
  if (!defaults) throw new Error(`Unknown model provider: ${provider}`)
  const base = (baseUrl || defaults.baseUrl).replace(/\/+$/, '')
  const body = defaults.kind === 'anthropic'
    ? await request(`${base}/v1/models?limit=1000`, { headers: { 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' } }, signal)
    : await request(`${base}/models`, { headers: { authorization: `Bearer ${apiKey}` } }, signal)
  const ids = (Array.isArray(body.data) ? body.data : []).map(item => item?.id).filter(id => typeof id === 'string' && id)
  return { models: [...new Set(ids)], default: defaults.model }
}

/** Returns { model, turn(system, history, tools, signal) → { text, toolCalls } }. */
export function createProvider({ provider, model, baseUrl, apiKey }) {
  const defaults = providerDefaults[provider]
  if (!defaults) throw new Error(`Unknown model provider: ${provider}`)
  const base = (baseUrl || defaults.baseUrl).replace(/\/+$/, '')
  const name = model || defaults.model
  if (defaults.kind === 'openai') {
    return {
      model: name,
      async turn(system, history, tools, signal) {
        const body = await request(`${base}/chat/completions`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
          body: JSON.stringify({
            model: name, messages: openaiMessages(system, history),
            tools: tools.map(tool => ({ type: 'function', function: { name: tool.name, description: tool.description, parameters: tool.inputSchema } })),
          }),
        }, signal)
        const choice = body.choices?.[0] ?? {}
        if (choice.finish_reason === 'length') throw new Error(truncated)
        const message = choice.message ?? {}
        return {
          text: message.content ?? '',
          toolCalls: (message.tool_calls ?? []).map(call => functionCall(call.id, call.function?.name, call.function?.arguments)),
        }
      },
    }
  }
  if (defaults.kind === 'responses') {
    return {
      model: name,
      async turn(system, history, tools, signal) {
        const body = await request(`${base}/responses`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
          body: JSON.stringify({
            model: name, instructions: system, input: responsesInput(history), store: false,
            tools: tools.map(tool => ({ type: 'function', name: tool.name, description: tool.description, parameters: tool.inputSchema })),
          }),
        }, signal)
        if (body.status === 'incomplete') throw new Error(truncated)
        const output = body.output ?? []
        return {
          text: output.filter(item => item.type === 'message').flatMap(item => item.content ?? [])
            .filter(part => part.type === 'output_text').map(part => part.text).join(''),
          toolCalls: output.filter(item => item.type === 'function_call').map(item => functionCall(item.call_id, item.name, item.arguments)),
        }
      },
    }
  }
  return {
    model: name,
    async turn(system, history, tools, signal) {
      const body = await request(`${base}/v1/messages`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
        body: JSON.stringify({
          model: name, max_tokens: 4096, system, messages: anthropicMessages(history),
          tools: tools.map(tool => ({ name: tool.name, description: tool.description, input_schema: tool.inputSchema })),
        }),
      }, signal)
      if (body.stop_reason === 'max_tokens') throw new Error(truncated)
      const blocks = body.content ?? []
      return {
        text: blocks.filter(block => block.type === 'text').map(block => block.text).join(''),
        toolCalls: blocks.filter(block => block.type === 'tool_use').map(block => ({ id: block.id, name: block.name, args: block.input ?? {} })),
      }
    },
  }
}
