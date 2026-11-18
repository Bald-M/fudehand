# Next-Message Prediction Design

Issue: #105.

## Intent

After a reply ends, what the user says next is often predictable ("Give every button a corner radius of 12"). The chat input shows that prediction as its placeholder, and Tab puts it in the input, so the user types less.

## Goals, non-goals, anti-goals

- **Goal**: once a reply has ended, the empty input's placeholder is the predicted next message with a *Tab* hint beside it; Tab fills the input with it, where it can be edited before sending.
- **Non-goals**: completing text while the user types; more than one candidate; a setting to turn predictions off.
- **Anti-goals**: a prediction that gets in the way. It never changes text the user typed, never blocks or delays sending, never shows an error, and is never written into the conversation or the harness's history.

## Approaches

- **The harness predicts after each reply (chosen)**: when a reply ends normally, the harness makes one extra model request with a short text-only transcript and emits `{type:'suggestion',text}`. One new output event, no new input message; the App only stores and shows the text. The harness is already running and already holds the provider, key, and history.
- The App asks for a prediction with a new `{type:'suggest'}` input message: lets the App decide when, but adds a second protocol message and request bookkeeping in Swift for the same result.
- The model appends the prediction to its reply (an instruction in the system prompt): no extra request, but the prediction would be part of the reply and of the history, which the issue rules out.

## Design

**Harness** (`scripts/agent-chat.mjs`). After `done`, when the reply was not stopped and reported no error, the harness calls `provider.turn` once more with:

- its own short system prompt asking for the single message the user is most likely to send next, in the user's language, with nothing else;
- one user message holding the last 8 user and assistant texts of the conversation (each cut to 1,500 characters), tool calls and results left out;
- no tools.

The answer is trimmed, reduced to its first non-empty line, stripped of surrounding quotes, and cut to 200 characters; when anything is left the harness emits `{type:'suggestion',text}`. The request is not added to the history, its usage is not reported, it times out after 15 seconds, and it is aborted by the next `user`, `stop`, or `load` message and when stdin closes. Every failure (no key, HTTP error, timeout, empty answer) is silent.

**Provider adapters** (`scripts/agent-providers.mjs`): `turn()` leaves `tools` out of the request when given none, since the Chat Completions API rejects an empty list.

**Transcript** (`FudehandCore/ChatTranscript.swift`): a `suggestion: String?` next to the entries. The `suggestion` event sets it unless a reply is running (a prediction that arrives after the next message was sent is stale). Sending and rewinding clear it. It is not part of the saved conversation.

**Chat panel** (`FudehandApp/ChatPanel.swift`): the input's placeholder is the selected conversation's suggestion, or *Message* when there is none. While the input is empty and a suggestion is shown, a *Tab* keycap sits at the input's trailing edge. With the input focused and empty, Tab sets the draft to the suggestion and puts the caret at its end; otherwise Tab keeps its normal behavior. The suggestion is not offered while the last message is being edited, since sending would replace that message with it. The placeholder is only shown while the draft is empty, so typed text is never replaced; clearing the input shows the suggestion again until the next message is sent.

## Testing

- Vitest (`tests/agent-chat.test.ts`): a suggestion follows `done`; the request has no tools and holds the transcript; the next turn's request does not contain it; no suggestion after a stopped or failed reply; a failing prediction emits nothing and the next message still works; a prediction in flight is dropped when the next message is sent.
- Swift (`ChatTranscriptTests`): the event sets the suggestion; it is ignored while busy; sending and rewinding clear it; it is not saved.
- Real App, light and dark: placeholder with the *Tab* hint, and the input after Tab. Screenshots in `docs/evidence/`.
