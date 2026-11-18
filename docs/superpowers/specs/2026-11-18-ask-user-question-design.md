# The Agent asks the user a question (issue #106)

## Intent

When a request is ambiguous ("add a bottom navigation to the home screen" without saying how many entries), the Agent in the chat
panel can only guess, and a wrong guess means rework. It should be able to pause, ask one question with options the user can click,
and carry on with the answer.

## Goals

- The Agent pauses its reply to ask one question, optionally with 2–4 options (each with an optional one-line description). The
  option it recommends comes first and is marked *Recommended*.
- The question shows as a card in the message list. The user clicks an option, types their own answer, or chooses
  *Skip, let AI decide*. The card then collapses to the question and the answer, and the Agent continues.
- No tool call runs while the question is unanswered. The panel and the conversation tab show a waiting state. Stopping the reply
  cancels the question.
- Works with all three model providers, and per conversation: a question in one tab does not block another tab.
- A conversation saved with an unanswered question still shows the card after quitting and reopening the App, and answering it
  lets the Agent continue.

## Non-goals

- Multiple-choice questions, or several questions at once.
- External agents using the question through MCP: it is not in `fudehand-tools.mjs`, and never touches the control channel.

## Approaches

1. **A tool defined in the harness (chosen).** `agent-chat.mjs` adds `ask_user` to the tool list it gives the model. Calling it
   emits a `question` event and waits for an `answer` line on stdin; the answer is the tool result. Provider-independent, since all
   three adapters already turn tool definitions and results into their own format. This is what the issue prescribes.
2. **A tool in `fudehand-tools.mjs` routed through the control channel.** Rejected: it would show up in the MCP server and tie a
   chat-panel interaction to the document's control protocol.
3. **Parsing a question out of the reply text.** Rejected: fragile, differs per model, and the turn would end instead of pausing.

## Design

### Harness protocol (`scripts/agent-chat.mjs`)

- Tool `ask_user`: `{ question: string, detail?: string, options?: [{ label: string, description?: string }] }`, 2–4 options when
  given. Its description tells the model to ask only when the request is ambiguous or key information is missing, to ask one
  question, and to put the option it recommends first. The system prompt gets one line saying the same.
- Output: `{type:'question', id, question, detail?, options}` (`id` is the tool call's id). No `tool_call`/`tool_result` events are
  emitted for it: the card is its representation.
- Input: `{type:'answer', id, question, text}` or `{type:'answer', id, question, skipped:true}`.
  - A question with that id is waiting: the answer becomes the tool result (`The user answered: …` /
    `The user skipped the question: decide yourself and carry on.`) and the reply continues.
  - Nothing is waiting and no reply is running (the harness was restarted since the question was asked): the answer starts a new
    turn, as a user message that restates the question and the answer. This is how a question survives quitting the App: the
    harness history is rebuilt from the saved texts (`load`), which never carried tool calls.
- Invalid arguments (no question, 1 or more than 4 options, an option without a label) and a second `ask_user` in the same round
  return an error result to the model without showing a card.
- `stop` (and `load`, and stdin closing) while waiting ends the wait; the call gets the usual "stopped; not executed" placeholder
  and the turn ends as stopped.

### Transcript (`FudehandCore/ChatTranscript.swift`)

- New entry kind `question`: `text` is the question, plus a `ChatQuestion` value (`detail`, `options`, `state`:
  `pending` / `answered(text)` / `skipped` / `cancelled`) and the call id.
- `apply` handles the `question` event. `answer(id, text?)` records the answer and, when no reply is running, marks one as started.
- `stop()` cancels a pending question. A new `suspend()` ends the reply but keeps the question pending; it is used where the harness
  goes away without the user stopping the reply (quitting, closing the tab, a restart after a settings or key change). Restoring a
  saved conversation also keeps it pending.
- `messages` (the history handed to a fresh harness) includes answered questions as an assistant text and a user text, so the
  context is not lost after a restart.
- `waiting`: whether the conversation has a pending question.

### Session (`FudehandApp/ChatSession.swift`)

- `answer(_ text: String?, root:, runtime:)` for the selected conversation: updates the transcript, starts and syncs the harness when
  needed (as `send` does), writes the `answer` line, and saves. The conversation is also saved when a question arrives.
- Shutdown, tab close, and harness restart call `suspend()` instead of `stop()`.

### UI (`ChatMessages.swift`, `ChatPanel.swift`)

Following the prototype's *Ask* artboard:

```
┌──────────────────────────────────────────┐
│ ? A quick question                       │
│ How many entries in the bottom nav?      │
│ The frame has only the home screen now…  │
│ ┌──────────────────────────────────────┐ │
│ │ 3: Home, Discover, Me  [Recommended] │ │
│ │ Icon and label, generous spacing     │ │
│ └──────────────────────────────────────┘ │
│ ┌ 4: Home, Discover, Messages, Me ─────┐ │
│ ┌ 5, with a publish button in the middle┐│
│ [ Other: write your own answer ] [Answer]│
│ Skip, let AI decide                      │
└──────────────────────────────────────────┘
```

- Answered: the card collapses to the question (small, secondary) over the answer (semibold): the chosen text, *Skipped, AI
  decides*, or *Question cancelled*.
- While waiting: the *Replying…* line reads *Waiting for your answer*; the tab's dot becomes a hollow orange ring; the stop button's
  label is *Stop and cancel the question*; the composer's placeholder invites answering there, and sending from the composer
  answers the question.
- All copy goes through `L(…)` with entries in the four string tables. Checked in the real App in light and dark; screenshots in
  `docs/evidence/`.

## Left to the builder

Exact spacing and colors of the card (system colors, matching the tool cards), test fixtures, and the wording of the model-facing
tool description.

## Calls made without asking

- The first option is always the recommended one; there is no separate flag.
- Answering after a restart replays the question and answer as a user message rather than restoring the original tool call.
- Closing a tab or changing the model's key while a question waits keeps the question pending instead of cancelling it.
- `docs/macos.md` and `GLOSSARY.md` (term *Question card*) are updated with the behavior.
