# Chat Slash Commands, Plan Mode, and Goal Mode Design

Issue: #103. Behavior as built is specified in [`docs/macos.md`](../../macos.md) ("Chat panel" → *Slash commands*, *Mode tag*).

## Intent

The chat panel could only send plain messages, and the Agent always edited the design document straight away. Slash commands add two ways of working — plan first and confirm, or set a goal and let the Agent run until it is done — and put the panel's common actions on the keyboard.

## Goals, non-goals, anti-goals

- **Goals**: a command menu opened by `/` at the start of the input, filtered as you type, usable by keyboard and mouse; `/plan`, `/goal`, `/new`, `/clear`, `/model`; a tag showing the conversation's mode, with a way out.
- **Non-goals**: user-defined commands; `/compact` (#104); saving the mode with the conversation.
- **Anti-goals**: a command reaching the model as text; an edit to the design document before a plan is confirmed.

## Approaches

- **Modes enforced in the Agent harness (chosen)**: the App sends `mode` with a user message, and the harness changes what the model is offered. Plan mode offers only the reading tools and refuses any other call, so "no edits before confirmation" holds even when the model ignores its instructions. Goal mode adds a `goal_done` tool that ends the loop.
- Modes as prompt text only, added by the App: no protocol change, but nothing stops a model from editing during a plan, which is the anti-goal.
- A separate plan/approve protocol with its own events: more precise, but the plan is just the reply's text and confirming is just the next message; a second protocol would duplicate both.

## Design

**Command parsing** (`FudehandCore/ChatCommands.swift`): `ChatCommandInput(draft)` classifies the input as a message, a command name being typed (with the commands it starts), a complete command with its argument, or an unknown command. Only a `/` at index 0 makes a command. `ModelMenu.choices` flattens the model menu's sections for `/model`.

**Conversation state** (`ChatSession`): each tab has `mode: ChatMode?` and `planReady`. `send` adds `mode` to the harness message. `send` also records the mode the reply was sent in, since a command can be run while a reply is going. When a reply sent as a goal ends, goal mode is cleared; `planReady` is set when the reply was sent in plan mode, the mode is still plan, and the reply ended with assistant text. `runPlan()` leaves plan mode and sends *Carry out the plan.*; `clearConversation()` empties the selected conversation in place.

**Harness** (`scripts/agent-chat.mjs`): `{type:'user', …, mode?: 'plan' | 'goal'}`; the mode applies to that message only.

| Mode | Tools offered | System prompt | Loop |
|---|---|---|---|
| plan | `design_get_state`, `design_get_document`, `design_get_node`, `design_snapshot`, `ask_user` | plus the plan note | unchanged; a call to any other tool gets an error result and is not run |
| goal | all tools, `ask_user`, and `goal_done {summary}` | plus the goal note | no round limit (an ordinary reply has 16): it runs until `goal_done`, the user stops it, or the model stops calling tools; `goal_done` ends the reply and its summary is emitted as an `assistant` event and kept in the history as the reply's last text; a round without tool calls gets one reminder, a second in a row ends the reply. The reminder is marked internal, so the next-message prediction does not read it as the user's words, and is reduced to *Continue.* once the reply ends |

The reading tools are an allow-list, so a tool added later is unavailable in plan mode until it is listed. An answer to a question that reaches a harness started anew carries the reply's `mode`, so the continued reply is still a plan.

**Panel** (`ChatPanel`): the menu is an overlay anchored to the top edge of the input. A local key monitor, active only while the menu is open and the input is focused, handles ↑, ↓, and Esc and leaves them alone while an input method is composing; Return goes through the text field's submit, which runs the highlighted command instead of sending.

## Calls made without asking

- `/clear` has no button to match: it empties the conversation in place (and so removes it from the history), rather than closing its tab as *Delete This Conversation* does.
- `/model` lists the models inside the command menu instead of opening the model menu, which SwiftUI cannot open from code.
- A message that starts with `/` followed by an unknown name — a file path, for example — is reported as an unknown command and not sent, as the issue requires.
- Goal mode is one-shot: it ends with the reply to the goal.
