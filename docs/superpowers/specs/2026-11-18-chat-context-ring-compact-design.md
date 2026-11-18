# Chat context ring and /compact — design

Issue: #104. Size: a small change (one feature across the harness, `FudehandCore`, and the chat panel).

## Intent

A long conversation fills the model's context window without the user seeing it, until the model API rejects a request and the
only way out is a new conversation. The chat panel should show how full the context is at all times, and let the user compact
it and keep going.

## Goals

- A context ring in the chat input shows the selected conversation's context usage as a share of the selected model's context
  window; hovering shows the numbers; it changes color near the limit; switching model recalculates against the new window.
- `/compact` replaces the earlier messages the model sees with a summary. The ring drops, later replies can still use what the
  summary kept, and the panel still shows every earlier message.
- Works for DeepSeek, Claude, and ChatGPT.

## Non-goals

- No automatic compaction.
- No cost or token price display.
- No command menu, and no handling of other commands or unknown commands: that is #103, which is not implemented yet.

## Approaches

**Where the context window comes from**

1. A table of model names in the App. Rejected: checked against the providers' docs on 2026-11-18, the windows this would have
   been written with were already wrong (DeepSeek's models are 1M now), so the table would be stale on arrival.
2. *(chosen)* Read it from the provider's model list, which the harness already fetches for the model menu: Anthropic reports
   `max_input_tokens` and DeepSeek `context_window` per model. OpenAI's list reports nothing, so the harness fills in the
   documented windows of its current families by id prefix. The App caches the windows next to the model list.
3. Ask the user to type the window in *Model settings*. Rejected: a number nobody knows by heart.

A model with no known window (a custom endpoint, a list fetched before this change) shows the tokens used without a share;
*Reload Model List* fills it in.

**What "used" is**

The input plus output tokens of the reply's last model request: what the next request will carry at the least. The harness
reports it in `done`; no tokenizer is needed. After a compaction it is the summary's output tokens, which leaves out the system
prompt and tool definitions until the next reply reports a real count.

**How /compact is invoked**

1. Wait for #103's command menu. Rejected: it blocks this issue on unstarted work.
2. *(chosen)* The input recognizes a message that is exactly `/compact`. #103 lists it in its menu later.
3. A button next to the ring. Rejected: the issue asks for the command, and the ring's tooltip already names it.

**How compaction works**

The harness sends the history plus one instruction asking for a summary, with the same system prompt and tools so the request
shape stays valid for histories with tool calls (and hits the prompt cache). On success it replaces its history with one user
message holding the summary. On failure or stop the history is unchanged.

## Design

- Harness protocol: input `{type:'compact'}`; output `{type:'compacted',summary}` before `done`; `done` gains `context` (tokens);
  `load` accepts `{role:'summary',text}`; `--list-models` output gains `windows: {id: tokens}`.
- `ChatTranscript`: a `summary` entry kind holds the summary and stays in the transcript, so the saved conversation records the
  compaction. `messages` (what a restarted harness is loaded with) starts at the last summary. Entries record `contextTokens`;
  the transcript's context usage is the newest one. `compacting` tells the panel which progress text to show.
- `ContextUsage` (Core): used tokens, optional window, share, and warning level (75 % and 90 %).
- Chat panel: the ring sits left of the send button. A compaction shows *Compacting context…*, can be stopped, and leaves a
  *Context compacted* row that expands to the summary. A failure adds a localized error row and changes nothing else.

## Left to the builder

Ring size and stroke, the wording of the summary instruction, test layout.
