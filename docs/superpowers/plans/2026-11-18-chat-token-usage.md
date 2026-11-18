# Chat Reply Token Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show under each chat reply the total tokens the model API reported for it, with the input / cached / output breakdown on hover.

**Architecture:** Each provider adapter returns a normalized `usage` per request; the harness sums it over the rounds of a reply and sends it in the `done` event; `ChatTranscript` stores it on the reply's last assistant entry; the message's action row draws it.

**Tech Stack:** Node 22 (`scripts/*.mjs`, Vitest), Swift 5 mode (AtlasCore, AtlasApp, swift-testing).

**Spec:** `docs/superpowers/specs/2026-11-18-chat-token-usage-design.md`

## Global Constraints

- Usage is only what the API reported; never estimated. No usage → nothing shown.
- `input` includes cached input tokens; `cached` is the part read from cache; total = `input + output`.
- Code comments, test names and error messages in English. UI copy only through `L("…")`, with the key in all four `Localizable.strings` tables.
- No new dependencies. Only touch what the feature needs.

## Review Focus

- A Chat Completions usage chunk has `choices: []` — the reply must still assemble, with usage read from that chunk (Task 1).
- A provider reports usage with missing or non-numeric counts — treated as no usage, not as zero or `NaN` (Task 1).
- An endpoint that ignores `stream` and answers plain JSON — usage is read from the body (Task 1).
- A reply stopped during its second round — `done` carries the first round's usage only (Task 2).
- A reply that ends with an error and no assistant text — usage is dropped without a crash, and an earlier reply's entry is not given it (Task 3).

---

### Task 1: Provider adapters return usage

**Files:**
- Modify: `scripts/agent-providers.mjs`
- Test: `tests/agent-chat.test.ts`

**Interfaces:**
- Produces: `turn(...)` resolves to `{ text, toolCalls, blocks?, usage? }` where `usage` is `{ input: number, output: number, cached: number }` (non-negative integers) or absent.

- [ ] **Step 1: Extend the test fixtures.** In `streamEvents`: for `/chat/completions`, when `body.usage` is set, append `{ choices: [], usage: body.usage }` after the finish chunk; for Anthropic, put `body.usage` minus `output_tokens` on `message_start.message.usage` and `{ output_tokens }` on `message_delta.usage`. The Responses fixture already sends the whole body in the closing event.

- [ ] **Step 2: Write failing tests** in a new `describe('Agent harness: token usage', …)`. They assert on the `done` event, so they also need Task 2; write both tasks' tests first, implement Task 1 then Task 2.

  - `reports the usage a Chat Completions stream ends with`: reply `{ ...openaiText('Hi.'), body.usage: { prompt_tokens: 120, completion_tokens: 30, prompt_cache_hit_tokens: 100 } }`; expect request body `stream_options` to equal `{ include_usage: true }` and `done` to equal `{ type: 'done', stopped: false, usage: { input: 120, output: 30, cached: 100 } }`. A second ask with `prompt_tokens_details: { cached_tokens: 7 }` instead gives `cached: 7`.
  - `reports Responses API usage`: `usage: { input_tokens: 200, output_tokens: 40, input_tokens_details: { cached_tokens: 150 } }` → `{ input: 200, output: 40, cached: 150 }`.
  - `counts Anthropic cache tokens as input`: `usage: { input_tokens: 10, cache_creation_input_tokens: 20, cache_read_input_tokens: 300, output_tokens: 50 }` → `{ input: 330, output: 50, cached: 300 }`.
  - `reads usage from a plain JSON body`: same Chat Completions reply with `json: true` → same usage.
  - `reports no usage when the API sends none or sends it malformed`: a reply without `usage`, then one with `usage: { prompt_tokens: 'many' }` → `done` equals `{ type: 'done', stopped: false }` both times.

- [ ] **Step 3: Run** `pnpm vitest run tests/agent-chat.test.ts -t "token usage"` — expect failures (no `usage` on `done`).

- [ ] **Step 4: Implement.** Add `function usage(input, output, cached)` in `agent-providers.mjs` that returns `{ input, output, cached: cached ?? 0 }` when `input` and `output` are non-negative integers (and `cached` is one or nullish), else `undefined`. Per adapter, carry the provider's raw usage object through the assembled body (so the JSON fallback reads the same field) and map it as the spec's table says; Chat Completions adds `stream_options: { include_usage: true }` to the request and reads `event.usage` from any chunk.

### Task 2: Harness sums usage into `done`

**Files:**
- Modify: `scripts/agent-chat.mjs` (`reply()`, protocol comment)
- Test: `tests/agent-chat.test.ts`

**Interfaces:**
- Consumes: `answer.usage` from Task 1.
- Produces: `{ type: 'done', stopped, usage?: { input, output, cached } }`.

- [ ] **Step 1: Write failing tests** in the same `describe`:

  - `adds up the usage of every round of a reply`: `openaiTool('call_1', 'design_get_state', {})` with `{ prompt_tokens: 100, completion_tokens: 10 }`, then `openaiText('Done.')` with `{ prompt_tokens: 150, completion_tokens: 20, prompt_cache_hit_tokens: 90 }` → `usage: { input: 250, output: 30, cached: 90 }`.
  - `reports no usage when one round did not report any`: same two rounds, the second without `usage` → `done` has no `usage` key.
  - `reports the completed rounds when the reply is stopped`: first round a tool call with usage `{ prompt_tokens: 100, completion_tokens: 10 }`, second round `delayMs: 1500`; send `{ type: 'stop' }` after the `tool_result` event → `done` equals `{ type: 'done', stopped: true, usage: { input: 100, output: 10, cached: 0 } }`.
  - `still reports usage when a later round fails`: first round tool call with usage, second `{ status: 500, body: {} }` → events end with `error` then `done` carrying the first round's usage.

- [ ] **Step 2: Implement.** In `reply()`, keep `let total = { input: 0, output: 0, cached: 0 }`, `let rounds = 0`, `let unreported = false`; after each `provider.turn` that returns (before the abort check), count the round and add `answer.usage` or set `unreported`. In `finally`, emit `usage: total` only when `rounds > 0 && !unreported`. Update the protocol comment's `done` line.

- [ ] **Step 3: Run** `pnpm vitest run tests/agent-chat.test.ts` — all pass, including the existing tests whose exact `done` expectations must be unchanged.

- [ ] **Step 4: Commit** Tasks 1–2: `feat(chat): harness 汇总并上报每轮回复的 token 用量`.

### Task 3: AtlasCore stores and formats usage

**Files:**
- Modify: `native/Sources/AtlasCore/ChatTranscript.swift`
- Test: `native/Tests/AtlasCoreTests/ChatTranscriptTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ChatUsage: Codable, Equatable, Sendable {
      public let input: Int, output: Int, cached: Int
      public var total: Int { input + output }
      public init(input: Int, output: Int, cached: Int)
      /// "856", "30.3K", "1.2M"
      public static func compact(_ count: Int) -> String
  }
  // ChatEntry
  public fileprivate(set) var usage: ChatUsage?
  ```

- [ ] **Step 1: Write failing tests:**

  - `chatTranscriptAttachesUsageToTheLastTextOfTheReply`: send, `assistant` "Checking", `tool_call`/`tool_result`, `assistant` "Done", `done` with `"usage":{"input":250,"output":30,"cached":90}` → only the "Done" entry has `usage == ChatUsage(input: 250, output: 30, cached: 90)`, and `usage?.total == 280`.
  - `chatTranscriptDropsUsageWhenTheReplyHasNoText`: first exchange ends with `done` without usage; second `send`, `error`, `done` with usage → no entry has usage.
  - `chatTranscriptKeepsUsageOfAStoppedReply`: `assistant_delta` "Half", `done` with `"stopped":true` and usage → the "Half" entry has the usage and the last entry is the stop notice.
  - `chatTranscriptIgnoresMalformedUsage`: `done` with `"usage":{"input":"x"}` → no usage, `busy == false`.
  - Extend `chatTranscriptIsRestoredFromSavedEntries`: usage round-trips through encode/decode, and `[{"id":0,"kind":"assistant","text":"Old","context":[]}]` (no `usage` key) decodes with `usage == nil`.
  - `chatUsageFormatsCompactCounts`: `0→"0"`, `856→"856"`, `999→"999"`, `1000→"1.0K"`, `30_349→"30.3K"`, `999_949→"999.9K"`, `999_950→"1.0M"`, `1_234_567→"1.2M"`.

- [ ] **Step 2: Run** `swift test --package-path native --filter AtlasCoreTests.chatTranscript` (through `node scripts/native-swift.mjs` as `pnpm test:native` does) — expect compile failure.

- [ ] **Step 3: Implement.** In `apply`'s `done` case, parse `usage` (all three values must be `Int`) and set it on the last `.assistant` entry after the last `.user` entry, before `stop()` / `settle()` runs. `compact` uses a fixed `.` decimal separator (`String(format:)`), switching to `M` at 999 950.

- [ ] **Step 4: Run** the same filter — pass. **Commit:** `feat(chat): 会话记录保存每轮回复的 token 用量`.

### Task 4: Chat panel shows usage

**Files:**
- Modify: `native/Sources/AtlasApp/ChatMessages.swift` (`AssistantMessage`)
- Modify: the four `native/Sources/AtlasCore/Resources/*/Localizable.strings`
- Modify: `docs/macos.md` ("Chat panel" section)
- Create: `docs/evidence/chat-token-usage-light.jpg`, `docs/evidence/chat-token-usage-dark.jpg`

**Interfaces:**
- Consumes: `entry.usage`, `ChatUsage.compact` from Task 3.

- [ ] **Step 1: Add the strings** next to "Regenerate" in each table:

  | Key | en / en-GB | zh-Hans | zh-Hant |
  |---|---|---|---|
  | `%@ tokens` | `%@ tokens` | `用量 %@ tokens` | `用量 %@ tokens` |
  | `Input %@ (%@ cached) · Output %@` | same | `输入 %@（缓存 %@）· 输出 %@` | `輸入 %@（快取 %@）· 輸出 %@` |

- [ ] **Step 2: Draw it.** In `AssistantMessage`'s action `HStack`, after the buttons, when `entry.usage` is set: `Text(L("%@ tokens", ChatUsage.compact(usage.total)))` in `.caption`, `.secondary`, `.monospacedDigit()`, with leading padding 4, `.help(L("Input %@ (%@ cached) · Output %@", …))` using `compact` for each value. It inherits the row's opacity rule.

- [ ] **Step 3: Document.** One sentence in `docs/macos.md`'s "Chat panel" section: what the number counts, where the breakdown is, and that nothing is shown when the provider reports no usage.

- [ ] **Step 4: Run the full gate:** `pnpm check` and `pnpm test:native` — all pass (the localization tests check the new keys).

- [ ] **Step 5: Verify in the real app** with `pnpm dev`: send a message that calls a tool, confirm the count and its tooltip, in light and dark appearance; save both screenshots to `docs/evidence/`.

- [ ] **Step 6: Commit:** `feat(chat): 对话面板显示每轮回复的 token 用量`.
