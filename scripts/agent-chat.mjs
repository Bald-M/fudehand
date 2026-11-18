import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { createInterface } from 'node:readline'
import { callTool, tools } from './fudehand-tools.mjs'
import { createProvider, listModels } from './agent-providers.mjs'
import { designGuidance } from './design-guidance.mjs'

/**
 * The Agent harness of the in-App chat panel. Started on demand by Fudehand, exchanging JSON lines over stdin/stdout:
 *   Input:  {type:'user',text,context?:[{id,name,type}],mode?:'plan'|'goal'} | {type:'stop'} | {type:'compact'}
 *        | {type:'load',messages:[{role:'user'|'assistant'|'summary',text}]}
 *        | {type:'answer',id,question,text,mode?} | {type:'answer',id,question,skipped:true,mode?}
 *   Output: {type:'assistant_delta',text} | {type:'assistant',text} | {type:'tool_call',id,name,args}
 *        | {type:'tool_result',id,name,ok,text} | {type:'question',id,question,detail?,options:[{label,description?}]}
 *        | {type:'compacted',summary} | {type:'error',message}
 *        | {type:'done',stopped,usage?:{input,output,cached},context?} | {type:'suggestion',text}
 * The reply text streams in as assistant_delta events; the assistant event that follows carries the complete text of that round.
 * `usage` is the tokens the model API reported for the reply, added up over its rounds: `input` includes the `cached` tokens.
 * It is left out when a round reported none, since the sum would understate the reply.
 * A `question` is the model calling the harness's own ask_user tool: the reply pauses, with no tool_call or tool_result event, until
 * the `answer` with that id arrives and becomes the tool's result. An `answer` to a question that is no longer waiting (the harness
 * was restarted since) starts a new turn that restates the question and the answer.
 * `done.context` is the tokens the conversation takes up in the model's context window: the input plus output of the reply's last request.
 * `compact` has the model summarize the conversation and replaces the history with that summary, reported in `compacted`; the
 * history is unchanged when that fails or is stopped. Its `done` carries the summary request's usage, and as `context` the
 * summary's own tokens. In `load`, a `summary` message is the summary an earlier compaction left.
 * `suggestion` is the predicted next user message. It may follow the `done` of a reply that ended normally, comes from a separate
 * model request that is kept out of the history and of `usage`, and is simply not sent when that request fails.
 * `context` lists the layers selected when the message was sent. `load` replaces the conversation history, for a new or reopened conversation.
 * `mode` applies to that one message. In plan mode the model gets only the tools that read the design document and replies with a plan;
 * the user confirms it with an ordinary message. In goal mode the message is a goal: the model keeps working, over more rounds than an
 * ordinary reply gets, until it calls goal_done, whose summary is sent as the reply's last assistant text.
 * The provider, model, baseUrl, and API key are passed only through environment variables; exits when stdin closes.
 * With --list-models it only prints one line, {type:'models',models,default,windows} or {type:'error',message}, then exits.
 */

const { values } = parseArgs({ options: { root: { type: 'string' }, 'list-models': { type: 'boolean' } } })
const ctx = { root: values.root ? resolve(values.root) : fileURLToPath(new URL('../', import.meta.url)) }
const apiKey = process.env.FUDEHAND_API_KEY ?? ''
const maximumRounds = 16
const maximumGoalRounds = 64
/** Goal mode: how many rounds in a row without tool calls get a reminder to go on; the next one ends the goal as it stands. */
const maximumGoalReminders = 3

/** The tools plan mode offers: the ones that only read the design document. A tool not listed here cannot run before the plan is confirmed. */
const readingTools = ['design_get_state', 'design_get_document', 'design_get_node', 'design_snapshot']

const planNote = 'Plan mode is on. Do not change the design document: only the tools that read it are available. Read what you need, then reply with a short numbered plan of the steps you would take, and ask the user to confirm it. You carry the plan out only after the user confirms.'
const planRefusal = 'Plan mode: the design document cannot be changed until the user confirms the plan.'

const goalNote = 'Goal mode is on. The user\'s message is a goal. Keep working with the tools until it is achieved, checking the result as you go, without asking the user to confirm each step. Do not end a round with only a progress note: each round should call a tool until the goal is done. When the goal is achieved, or you are certain it cannot be, call goal_done with a summary of the result for the user.'
const goalReminder = 'Goal mode: the goal has not been marked as done. Continue working on it, or call goal_done with a summary if it is achieved or cannot be.'
const goalDone = {
  name: 'goal_done',
  description: 'End goal mode: call this once the goal is achieved, or when it cannot be. The summary is shown to the user as the result.',
  inputSchema: { type: 'object', properties: { summary: { type: 'string', description: 'What was done and the result, in the user\'s language' } }, required: ['summary'] },
}

let provider = null
let providerError = null
try { provider = createProvider({ provider: process.env.FUDEHAND_PROVIDER || 'deepseek', model: process.env.FUDEHAND_MODEL, baseUrl: process.env.FUDEHAND_BASE_URL, apiKey }) }
catch (error) { providerError = error.message }

const system = [
  'You are the design assistant built into Fudehand. Fudehand is a native design tool: the canvas shows a design document made of layers, and you and the user edit the same document.',
  // Models cannot tell which model they are and otherwise name whichever one their training data mentions most.
  provider && `You are running on the model "${provider.model}" (provider setting: ${process.env.FUDEHAND_PROVIDER || 'deepseek'}). If asked which model you are, answer with that and do not claim to be any other model.`,
  'First use design_get_state or design_get_document to learn the current state, then make changes with design_create_node, design_update_node, design_delete_nodes, and design_move_node; the canvas updates immediately after each change.',
  'When building a UI, prefer frames with auto layout (layout), and create a whole group of layers with children in a single design_create_node call; mobile frames are usually 390×844.',
  provider?.images === false
    ? 'You cannot see images, so design_snapshot gives you no picture: after making changes, read them back with design_get_node or design_get_document to check the result, adjust if something is off, and do not claim to have looked at the design.'
    : 'After making changes, take a design_snapshot to check the result, and adjust if something is off.',
  'Undo with design_undo; save with design_save_document.',
  'When the request is ambiguous or lacks information that would change what you build, ask with ask_user before building instead of guessing: one question at a time, with the option you recommend first. Do not ask about what you can read from the document or decide sensibly yourself.',
  'Reply in the same language as the user\'s latest message, and briefly explain what you did.',
  `\n${designGuidance}`,
].filter(Boolean).join('\n')

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
    const settings = { provider: process.env.FUDEHAND_PROVIDER || 'deepseek', baseUrl: process.env.FUDEHAND_BASE_URL, apiKey }
    emit({ type: 'models', ...await listModels(settings, AbortSignal.timeout(15000)) })
  } catch (error) {
    emit({ type: 'error', message: error?.name === 'TimeoutError' ? 'Timed out fetching the model list' : String(error?.message ?? error) })
  }
  // Pipe writes are asynchronous on macOS; wait for the output to be written before exiting, so it is not truncated when there are many models.
  await new Promise(resolve => process.stdout.write('', resolve))
  process.exit(0)
}

let history = []
let current = null
/** The question waiting for the user's answer: { id, resolve }. */
let asking = null
/** The ids of the questions this process asked: a late answer to one of them (after a stop) must not start a new turn. */
const asked = new Set()

/** The harness's own tool: it never reaches the App's control channel, and the MCP server does not offer it. */
const askTool = {
  name: 'ask_user',
  description: 'Pause and ask the user one question when the request is ambiguous or lacks information that would change what you build. The user picks an option, writes their own answer, or skips to let you decide; the answer is returned as the result. Ask one question per call and wait for its answer before asking another.',
  inputSchema: {
    type: 'object',
    properties: {
      question: { type: 'string', description: 'The question, one short sentence in the user\'s language' },
      detail: { type: 'string', description: 'One sentence on why you ask or what the answer changes' },
      options: {
        type: 'array', minItems: 2, maxItems: 4, description: '2–4 answers to pick from, the one you recommend first; it is shown as recommended',
        items: { type: 'object', properties: { label: { type: 'string', description: 'The answer, a few words' }, description: { type: 'string', description: 'One sentence on what this choice means' } }, required: ['label'] },
      },
    },
    required: ['question'],
  },
}

const text = value => typeof value === 'string' ? value.trim() : ''

/** The question as shown to the user, or the error to hand back to the model when the arguments cannot be shown as a card. */
function parseQuestion(args) {
  const question = text(args?.question)
  if (!question) return { error: 'question must be a non-empty string' }
  const options = args.options ?? []
  if (!Array.isArray(options) || (options.length && (options.length < 2 || options.length > 4))) return { error: 'options must hold 2 to 4 entries, or be left out' }
  if (options.some(option => !text(option?.label))) return { error: 'every option needs a non-empty label' }
  return {
    question, ...(text(args.detail) ? { detail: text(args.detail) } : {}),
    options: options.map(option => ({ label: text(option.label), ...(text(option.description) ? { description: text(option.description) } : {}) })),
  }
}

const skippedAnswer = 'The user skipped the question: decide yourself and carry on.'
const answerText = answer => answer.skipped === true ? skippedAnswer : `The user answered: ${text(answer.text)}`

/** Shows the question and waits for its answer; resolves with null when the reply is stopped first. */
function ask(id, question, signal) {
  return new Promise(resolve => {
    const finish = answer => { asking = null; signal.removeEventListener('abort', stopped); resolve(answer) }
    const stopped = () => finish(null)
    signal.addEventListener('abort', stopped)
    asking = { id, resolve: finish }
    asked.add(id)
    emit({ type: 'question', id, ...question })
  })
}

// The next-message prediction in progress, if any.
let predicting = null

const predictionSystem = [
  'Predict the next message the user of a design tool will send to its AI design assistant, given the end of their conversation.',
  'Reply with that one message only, written as the user would type it, in the language of the user\'s messages: one short line, no quotes, no explanation.',
].join('\n')

/**
 * Asks the model what the user is likely to say next and emits it as a suggestion. The request holds only the last few texts of
 * the conversation and is not added to the history; any failure leaves the App without a suggestion.
 */
async function predict(log) {
  const controller = predicting = new AbortController()
  const texts = log.filter(entry => (entry.role === 'user' || entry.role === 'assistant') && entry.text && !entry.internal).slice(-8)
    .map(entry => `${entry.role === 'user' ? 'User' : 'Assistant'}: ${entry.text.slice(0, 1500)}`)
  try {
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(15000)])
    const answer = await provider.turn(predictionSystem, [{ role: 'user', text: texts.join('\n\n') }], [], signal, () => {})
    const line = answer.text.split('\n').map(part => part.trim()).find(Boolean) ?? ''
    const text = line.replace(/^["'“‘「『]+|["'”’」』]+$/g, '').trim().slice(0, 200)
    if (text && !controller.signal.aborted) emit({ type: 'suggestion', text })
  } catch {} finally {
    if (predicting === controller) predicting = null
  }
}

const imagesOmitted = 'The image was left out because the current model provider cannot receive images. Check the result with design_get_node or design_get_document instead.'

const imageTooLarge = 'The image was left out because it is larger than 8000 px on a side, which the model API rejects. Take the snapshot again with a smaller scale.'

/** Whether a PNG is wider or taller than the model APIs accept; an oversized image would be rejected again on every later request. */
function tooLarge(image) {
  const header = Buffer.from(image.data.slice(0, 32), 'base64')
  return header.length >= 24 && Math.max(header.readUInt32BE(16), header.readUInt32BE(20)) > 8000
}

function toolText(result) {
  return result.content.filter(item => item.type === 'text').map(item => item.text).join('\n')
}

/** Puts the layers the user had selected in front of the message, so the model knows what "this" refers to. */
function withContext(text, context) {
  const layers = (Array.isArray(context) ? context : []).filter(layer => layer && typeof layer.id === 'string')
    .map(layer => `${JSON.stringify(String(layer.name ?? ''))} (${layer.type}, id ${layer.id})`)
  return layers.length ? `The user has these layers selected: ${layers.join(', ')}\n\n${text}` : text
}

async function reply(text, controller, mode) {
  const { signal } = controller
  const plan = mode === 'plan'
  const goal = mode === 'goal'
  // A question changes nothing in the design document, so the model may ask one in every mode.
  const offered = [...(plan ? tools.filter(tool => readingTools.includes(tool.name)) : goal ? [...tools, goalDone] : tools), askTool]
  const prompt = plan ? `${system}\n\n${planNote}` : goal ? `${system}\n\n${goalNote}` : system
  // Goal mode: how many rounds in a row without tool calls the model was told to go on after, and whether it reported the goal done.
  let reminded = 0
  let finished = false
  let summary = ''
  const reminders = []
  // Loading a conversation replaces history; this turn's reply always goes into the history it started with.
  const log = history
  log.push({ role: 'user', text })
  // The text of the round in progress: kept in the history when the user stops the reply halfway.
  let partial = ''
  // The usage of the rounds that completed; `reported` turns false when one of them came without any.
  const usage = { input: 0, output: 0, cached: 0 }
  let rounds = 0
  let reported = true
  let failed = false
  // What the conversation takes up after the last round that completed; unknown when that round reported no usage.
  let context
  const count = round => {
    rounds++
    if (round.usage) for (const key in usage) usage[key] += round.usage[key]
    else reported = false
  }
  try {
    if (providerError) throw new Error(providerError)
    if (!apiKey) throw new Error('No API key configured')
    for (let round = 0; ; round++) {
      if (round === (goal ? maximumGoalRounds : maximumRounds)) throw new Error('Too many tool-call rounds; stopped this reply')
      const answer = await provider.turn(prompt, log, offered, signal, delta => { if (delta) { partial += delta; emit({ type: 'assistant_delta', text: delta }) } })
      count(answer)
      context = answer.usage && answer.usage.input + answer.usage.output
      if (signal.aborted) break
      // Neither API accepts an empty reply written back into the history, so end this turn right away.
      if (!answer.text && !answer.toolCalls.length) break
      log.push({ role: 'assistant', text: answer.text, toolCalls: answer.toolCalls, blocks: answer.blocks })
      partial = ''
      if (answer.text) emit({ type: 'assistant', text: answer.text })
      if (!answer.toolCalls.length) {
        // A goal ends with goal_done; a round without tool calls gets a reminder, and only too many in a row end the goal as it stands.
        if (!goal || reminded === maximumGoalReminders) break
        reminded++
        reminders.push({ role: 'user', text: goalReminder, internal: true })
        log.push(reminders.at(-1))
        continue
      }
      reminded = 0
      let questioned = false
      for (const call of answer.toolCalls) {
        // After a stop, no further tool calls are executed; placeholder results are only filled in for the model to keep the history complete.
        if (signal.aborted) { log.push({ role: 'tool', id: call.id, name: call.name, text: 'The user stopped this reply; not executed.' }); continue }
        if (call.name === askTool.name) {
          const question = call.error ? { error: call.error }
            : questioned ? { error: 'ask one question at a time, and wait for its answer before asking another' } : parseQuestion(call.args)
          if (question.error) { log.push({ role: 'tool', id: call.id, name: call.name, isError: true, text: `ask_user: ${question.error}` }); continue }
          questioned = true
          const given = await ask(call.id, question, signal)
          log.push({ role: 'tool', id: call.id, name: call.name, text: given ? answerText(given) : 'The user stopped this reply; not executed.' })
          continue
        }
        if (goal && call.name === goalDone.name && !call.error) {
          finished = true
          log.push({ role: 'tool', id: call.id, name: call.name, text: 'Goal mode ended.' })
          if (typeof call.args?.summary === 'string') summary = call.args.summary
          continue
        }
        emit({ type: 'tool_call', id: call.id, name: call.name, args: call.args })
        const result = call.error ? { isError: true, content: [{ type: 'text', text: call.error }] }
          : plan && !readingTools.includes(call.name) ? { isError: true, content: [{ type: 'text', text: planRefusal }] }
          : await callTool(call.name, call.args, ctx)
        const output = toolText(result)
        const images = result.content.filter(item => item.type === 'image').map(item => ({ data: item.data, mimeType: item.mimeType }))
        log.push({
          role: 'tool', id: call.id, name: call.name, isError: Boolean(result.isError),
          ...(!images.length ? { text: output }
            : !provider.images ? { text: `${output}\n${imagesOmitted}` }
            : images.some(tooLarge) ? { text: `${output}\n${imageTooLarge}` }
            : { text: output, images }),
        })
        emit({ type: 'tool_result', id: call.id, name: call.name, ok: !result.isError, text: output.slice(0, 4000) })
      }
      if (finished) {
        // The summary is the reply's last text, in the history as well as in the panel.
        if (summary && !signal.aborted) { log.push({ role: 'assistant', text: summary, toolCalls: [] }); emit({ type: 'assistant', text: summary }) }
        break
      }
      if (signal.aborted) break
    }
  } catch (error) {
    // A request that completed with a reply that cannot be used (cut off, declined) was consumed like any other.
    if (error instanceof Error && 'usage' in error) count(error)
    failed = true
    if (!signal.aborted) emit({ type: 'error', message: error instanceof Error ? error.message : String(error) })
  } finally {
    if (signal.aborted && partial) log.push({ role: 'assistant', text: partial, toolCalls: [] })
    current = null
    // goal_done is offered only to this reply, so the reminders must not ask later replies for it.
    for (const reminder of reminders) reminder.text = 'Continue.'
    emit({ type: 'done', stopped: signal.aborted, ...(rounds && reported ? { usage } : {}), ...(context ? { context } : {}) })
    // The panel shows no prediction in plan mode, where the next step is to confirm or change the plan.
    if (!signal.aborted && !failed && !plan) void predict(log)
  }
}

const summaryRequest = [
  'Summarize this conversation so that it can continue from your summary alone; the messages above will be removed.',
  'Cover what the user asked for and the preferences they stated, the decisions made, the current state of the design document (name the layers that were created or changed, with their ids), and anything left unfinished.',
  'Write it in the language the user has been using. Reply with the summary only, and do not call any tools.',
].join(' ')

const summaryHeading = 'The earlier part of this conversation was compacted to free up context. This is its summary:'

function summaryMessage(summary) {
  return { role: 'user', text: `${summaryHeading}\n\n${summary}` }
}

/** Has the model summarize the conversation, then replaces the history with the summary. A failure or a stop leaves the history as it was. */
async function compact(controller) {
  const { signal } = controller
  const log = history
  let usage
  try {
    if (providerError) throw new Error(providerError)
    if (!apiKey) throw new Error('No API key configured')
    if (!log.length) throw new Error('There is nothing to compact yet')
    // The same system prompt and tools as a reply: a history with tool calls is only valid with its tools, and the request can reuse the prompt cache.
    const answer = await provider.turn(system, [...log, { role: 'user', text: summaryRequest }], [...tools, askTool], signal, () => {})
    if (signal.aborted) return
    usage = answer.usage
    if (!answer.text.trim()) throw new Error('The model returned no summary; the context was not compacted')
    log.splice(0, log.length, summaryMessage(answer.text))
    emit({ type: 'compacted', summary: answer.text })
  } catch (error) {
    usage = undefined
    if (!signal.aborted) emit({ type: 'error', message: error instanceof Error ? error.message : String(error) })
  } finally {
    current = null
    // Until the next reply reports a real count, the summary's own tokens stand for the context; the system prompt and tools are not in them.
    emit({ type: 'done', stopped: signal.aborted, ...(usage ? { usage, context: usage.output } : {}) })
  }
}

const input = createInterface({ input: process.stdin })
input.on('line', line => {
  let message
  try { message = JSON.parse(line) } catch { return emit({ type: 'error', message: 'Received an unparseable message' }) }
  // A prediction still in progress is for a conversation state that this message is about to change.
  if (['user', 'answer', 'compact', 'stop', 'load'].includes(message.type)) predicting?.abort()
  if (message.type === 'user' && typeof message.text === 'string') {
    if (current) return emit({ type: 'error', message: 'The previous reply has not finished yet' })
    current = new AbortController()
    void reply(withContext(message.text, message.context), current, message.mode)
  } else if (message.type === 'answer') {
    if (asking) { if (asking.id === message.id) asking.resolve(message) }
    else if (!current && !asked.has(message.id) && typeof message.question === 'string') {
      current = new AbortController()
      void reply(`You asked the user: ${message.question}\n${answerText(message)}`, current, message.mode)
    }
  } else if (message.type === 'compact') {
    if (current) return emit({ type: 'error', message: 'The previous reply has not finished yet' })
    current = new AbortController()
    void compact(current)
  } else if (message.type === 'stop') {
    current?.abort()
  } else if (message.type === 'load' && Array.isArray(message.messages)) {
    current?.abort()
    history = message.messages.filter(entry => typeof entry?.text === 'string' && entry.text && ['user', 'assistant', 'summary'].includes(entry.role))
      .map(entry => entry.role === 'user' ? { role: 'user', text: entry.text }
        : entry.role === 'summary' ? summaryMessage(entry.text) : { role: 'assistant', text: entry.text, toolCalls: [] })
  }
})
input.on('close', () => {
  current?.abort()
  process.exit(0)
})
