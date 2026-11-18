# Agent Asks the User a Question Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The chat panel's Agent can pause a reply to ask one question with clickable options, and continue with the answer.

**Architecture:** The harness (`scripts/agent-chat.mjs`) owns an `ask_user` tool: a call emits a `question` event and waits for an `answer` line; the answer is the tool result. The transcript (`FudehandCore`) models the question as an entry with a state, `ChatSession` routes answers, and SwiftUI draws the card.

**Tech Stack:** Node 22 (harness, Vitest), Swift 5 mode (FudehandCore, FudehandApp, XCTest/swift-testing as the existing tests use), SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-18-ask-user-question-design.md`

## Global Constraints

- `ask_user` is defined only in `scripts/agent-chat.mjs`; `scripts/fudehand-tools.mjs`, the MCP server, and the control channel do not change.
- One question at a time, single choice; 2–4 options when options are given.
- UI copy only through `L("English")`, with the key in all four `Localizable.strings` tables; harness/protocol errors stay English.
- Comments, test names, and docs in English.
- UI checked in the real App, light and dark; screenshots in `docs/evidence/`.

## Review Focus

- A `stop` while a question waits: no later tool call runs, the turn ends as stopped, the card reads cancelled.
- An `answer` whose id matches nothing while a reply is running (a stale click): ignored, no second turn starts.
- A saved conversation with a pending question restored at launch: the question stays pending (not failed), `busy` is false.
- A model that sends 1 option, 5 options, or an empty question: an error result goes back to the model, no card appears.
- A conversation file saved by an older version (entries without the question field) still loads.

---

### Task 1: Harness `ask_user` tool

**Files:**
- Modify: `scripts/agent-chat.mjs`
- Test: `tests/agent-chat.test.ts`

**Interfaces:**
- Produces (stdout): `{type:'question', id, question, detail?, options:[{label, description?}]}`.
- Consumes (stdin): `{type:'answer', id, question, text}` | `{type:'answer', id, question, skipped:true}`.
- Tool results: `The user answered: <text>` / `The user skipped the question: decide yourself and carry on.`
- Fallback turn (nothing waiting, no reply running) user text: `You asked the user: <question>\nThe user answered: <text>` or
  `You asked the user: <question>\nThe user skipped the question: decide yourself and carry on.`

- [ ] **Step 1: Failing tests** (in the style of the existing harness tests, with `fakeModel` and the three providers):
  - `ask_user` is in the tool list sent to each provider (DeepSeek, Claude, OpenAI), and not in `tools` of `fudehand-tools.mjs`.
  - A model reply calling `ask_user` yields a `question` event and no `tool_call`/`tool_result` events; no further model request is made until `answer` is written; after it, the next request carries the tool result `The user answered: 3 entries`, and the turn ends with `done`.
  - `skipped:true` yields the skip result text.
  - `stop` while waiting: `done` has `stopped:true`; a tool call that followed `ask_user` in the same round never reaches the fake App.
  - Invalid arguments (`options` of length 1 and 5, empty `question`, option without `label`) and a second `ask_user` in one round: no `question` event for the invalid call; its tool result in the next request is an error.
  - `answer` with no reply running starts a turn whose user message is the fallback text; `answer` with an unknown id while a reply runs is ignored.
- [ ] **Step 2: Run** `pnpm vitest run tests/agent-chat.test.ts` — the new tests fail.
- [ ] **Step 3: Implement** in `agent-chat.mjs`: the `askTool` definition, one system-prompt line, a `pending` slot (`{id, resolve}`) resolved by `answer` and by abort, validation, and the `answer` input branch. Update the protocol comment at the top.
- [ ] **Step 4: Run** the file again — all pass. **Step 5: Commit** `feat(agent): harness 增加 ask_user 提问工具`.

### Task 2: Transcript question entries

**Files:**
- Modify: `native/Sources/FudehandCore/ChatTranscript.swift`
- Test: `native/Tests/FudehandCoreTests/ChatTranscriptTests.swift`, `ChatHistoryTests.swift`

**Interfaces (produces):**
```swift
public struct ChatQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable { public let label: String; public let description: String? }
    public enum State: Codable, Equatable, Sendable { case pending, answered(String), skipped, cancelled }
    public let detail: String?
    public let options: [Option]
    public internal(set) var state: State
}
// ChatEntry.Kind gains `.question`; ChatEntry gains `public var question: ChatQuestion?` (text = the question).
// ChatTranscript:
public var pendingQuestion: ChatEntry? { get }        // the entry of the unanswered question, if any
public var waiting: Bool { get }                      // pendingQuestion != nil
public mutating func answer(_ text: String?) -> [String: Any]?   // nil text = skip; returns the harness `answer` message, nil when nothing is pending
public mutating func suspend()                        // ends the reply, keeps a pending question
```

- [ ] **Step 1: Failing tests:** the `question` event appends a pending question entry and keeps `busy`; `answer("x")` sets `.answered("x")`, returns `["type":"answer","id":…,"question":…,"text":"x"]`; `answer(nil)` sets `.skipped` and returns `skipped: true`; answering when not busy sets `busy`; `stop()` cancels the pending question; `suspend()` keeps it pending with `busy == false`; `init(entries:)` keeps it pending; `messages` includes an answered question as assistant text + user text and leaves out pending/cancelled ones; a question entry round-trips through `ChatHistory`; JSON of an entry without `question` still decodes; `rewind()` removes a question after the last user message; `groups` never folds a question into tool steps.
- [ ] **Step 2: Run** `swift test --package-path native --filter FudehandCoreTests.ChatTranscript` (through `node scripts/native-swift.mjs` as `pnpm test:native` does) — fail.
- [ ] **Step 3: Implement.** **Step 4: Run** — pass. **Step 5: Commit** `feat(chat): 对话记录支持提问条目`.

### Task 3: Session routing

**Files:**
- Modify: `native/Sources/FudehandApp/ChatSession.swift`
- Test: `native/Tests/FudehandAppTests/ChatSessionTests.swift`

**Interfaces:**
- Consumes: Task 2's `answer`, `suspend`, `waiting`.
- Produces: `func answer(_ text: String?, root: URL?, runtime: WorkspaceLocation?)` on `ChatSession` (selected conversation).

- [ ] **Step 1: Failing tests** (using the existing fake-harness approach in `ChatSessionTests`): answering writes the `answer` line to the live harness; a question in tab A leaves tab B able to send; a conversation saved with a pending question is restored pending by a new `ChatSession` with the same `ChatHistory`, and `answer` then starts a harness, sends `load` and the `answer` line; `shutdown()` and `close(_:)` keep the question pending in the saved file; `stopReply()` followed by the harness's `done stopped` cancels it.
- [ ] **Step 2: Run** `--filter FudehandAppTests.ChatSession` — fail. **Step 3: Implement** (`answer`; save when a question arrives; `suspend()` in `shutdown`, `close`, `restart`). **Step 4: Run** — pass. **Step 5: Commit** `feat(chat): 会话转发提问的回答并在重启后续答`.

### Task 4: Question card and waiting state

**Files:**
- Modify: `native/Sources/FudehandApp/ChatMessages.swift`, `ChatPanel.swift`, the four `Localizable.strings`
- Modify: `docs/macos.md` (Chat panel section), `GLOSSARY.md` (*Question card (问题卡片 / 問題卡片)*)

Copy (en / zh-Hans): `A quick question` / `AI 想先确认一下`; `Recommended` / `推荐`; `Other: write your own answer` / `其他：自己写回答`; `Answer` / `回答`; `Skip, let AI decide` / `跳过，由 AI 决定`; `Skipped, AI decides` / `已跳过，由 AI 决定`; `Question cancelled` / `提问已取消`; `Waiting for your answer` / `等待你回答`; `Stop and cancel the question` / `停止并取消提问`; `Answer the question above, or add details here` / `回答上面的问题后继续，也可以直接在这里补充`. en-GB equals en; zh-Hant is the Traditional form.

- [ ] **Step 1:** Add the keys to the four tables; add `answer: (String?) -> Void` to `ChatRowActions`; add `QuestionCard` (pending layout per the spec sketch; collapsed layout otherwise) and the `.question` case in `ChatGroupRow`.
- [ ] **Step 2:** In `ChatPanel`: waiting line, hollow orange ring on the tab, stop button label, composer placeholder, and `submit()` answering when `transcript.waiting`.
- [ ] **Step 3: Run** `pnpm test:native` — passes (LocalizationTests cover the keys).
- [ ] **Step 4:** Update `docs/macos.md` and `GLOSSARY.md`. **Step 5: Commit** `feat(chat): 问题卡片与待回答状态`.

### Task 5: Verify in the real App

- [ ] `pnpm check` and `pnpm test:native` pass.
- [ ] `pnpm dev`; with a real provider key if one is saved (otherwise a local fake model through the base URL), send an ambiguous request; check the card, an option click, a custom answer, skip, stop, a second tab, and quit-and-reopen. Capture light and dark screenshots to `docs/evidence/106-question-card-{light,dark}.png`.
- [ ] Commit the evidence.
