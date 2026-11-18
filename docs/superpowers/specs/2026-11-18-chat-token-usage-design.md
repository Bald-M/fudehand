# Chat Reply Token Usage Design

## Intent

After each reply in the chat panel, show roughly how many tokens that reply consumed, so the user can see what a request costs and notice when a conversation is getting expensive (long history, snapshots). The number comes from the model API's own usage report, not from an estimate.

## Goals, non-goals, anti-goals

- **Goal**: one number per reply — the total tokens of every model request made for it (input + output, summed over all tool-call rounds) — with the input / cached / output breakdown on hover.
- **Non-goals**: cost in money (needs a price table that custom base URLs and models break); a running total per conversation; a context-window meter; conversations run by an external Agent through the MCP connector, which do not pass through the harness.
- **Anti-goal**: showing a number that is wrong. When the provider reports no usage, nothing is shown; the harness never estimates.

## Approaches

- **Total in the `done` event (chosen)**: the harness sums usage over the rounds of a reply and sends it once, in the event that already ends the reply. One new optional field in the protocol, one in the saved entry.
- A `usage` event per round, summed by the App: lets the number tick up live, but adds a protocol event and moves the summing into Swift for no benefit the user asked for.
- Estimating tokens locally from text length: works for every provider but is inaccurate (tool definitions, images, cache), which is the anti-goal.

The user chose the single "total for this reply" figure over showing input and output separately.

## Design

**Provider adapters** (`scripts/agent-providers.mjs`): `turn()` also returns `usage: { input, output, cached }`, or no `usage` when the API reported none. `input` is all input tokens including cached ones; `cached` is the part read from cache.

| Provider kind | Source | Mapping |
|---|---|---|
| `openai` (Chat Completions) | request adds `stream_options: { include_usage: true }`; the last chunk's `usage` | `input = prompt_tokens`, `output = completion_tokens`, `cached = prompt_cache_hit_tokens ?? prompt_tokens_details.cached_tokens ?? 0` |
| `responses` | `response.usage` of the closing event | `input = input_tokens`, `output = output_tokens`, `cached = input_tokens_details.cached_tokens ?? 0` |
| `anthropic` | `message_start.message.usage` and `message_delta.usage` | `input = input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, `output = output_tokens` (from `message_delta`), `cached = cache_read_input_tokens` |

The non-streamed JSON fallback reads the same fields from the body.

**Harness** (`scripts/agent-chat.mjs`): `reply()` adds up the usage of each round and emits `{ type: 'done', stopped, usage?: { input, output, cached } }`. `usage` is left out when any completed round reported none (the sum would understate the reply) or when no round completed. A reply that is stopped or fails still reports the rounds that completed, since those were consumed; the interrupted round is not counted. A round that completed but whose reply is rejected (cut off by the length limit, declined, paused) is counted, because the request was consumed.

**AtlasCore** (`ChatTranscript.swift`): a `ChatUsage` value (`input`, `output`, `cached`, and `total = input + output`) and an optional `usage` on `ChatEntry`. On `done`, the usage is attached to the last assistant entry of the reply to the last user message; a reply with no assistant text shows no usage. Saved conversations without the field keep loading. A formatter gives the compact count: `856`, `30.3K`, `1.2M`.

**UI** (`ChatMessages.swift`): the count sits at the end of the reply's action row, in the secondary caption style, and follows that row's visibility (always shown on the newest reply, on hover for earlier ones):

```
[copy] [regenerate]   30.3K tokens
```

Hovering it shows the breakdown, e.g. `Input 29.8K (12.0K cached) · Output 512`. Copy goes through `L(…)` with entries in all four string tables.

**Docs**: the protocol comment at the top of `agent-chat.mjs`, the "Chat panel" section of `docs/macos.md`, and light and dark evidence screenshots in `docs/evidence/`.

## Tests

- Vitest: each adapter's usage mapping (including a stream with no usage), the harness summing over a tool-call round, and `usage` being left out when a round reports none.
- Swift: `done` with usage lands on the reply's last assistant entry; a saved entry without `usage` decodes; the compact formatter; the localization table checks.

## Left to the builder

Exact wording of the two strings and their translations, and where the formatter lives in AtlasCore.
