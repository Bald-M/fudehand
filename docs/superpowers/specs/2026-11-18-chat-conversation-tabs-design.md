# Chat Conversation Tabs Design

Issue: #100.

## Intent

Let the user work on two things with the Agent at once (say, building a page in one conversation and tuning colors in another) without clearing the conversation or mixing unrelated context into it.

## Goals, non-goals, anti-goals

- **Goals**: several conversations open at once as tabs at the top of the chat panel; each has its own messages, context, and model; a reply keeps running while another tab is shown, and its tab shows that it is in progress; closing a tab stops its reply; quitting the App ends every harness.
- **Non-goals**: binding conversations to design documents and restoring the open tabs and their models at launch (#102); renaming or reordering tabs; history search; sync.
- **Anti-goal**: events of one conversation's reply landing in another conversation.

## What changed since the issue was written

The issue describes a panel with one in-memory conversation. Since then (#130) conversations are saved under `~/Library/Application Support/ui-atlas/chats` and reopened from the *Conversation history* menu, and switching was blocked while a reply ran. Tabs are therefore built on top of that history rather than replacing it:

- A tab is an open conversation. Closing a tab does not delete the conversation; it stays in the history menu. *Delete This Conversation* still deletes it (and closes its tab).
- Choosing a conversation in the history menu selects its tab when it is already open; otherwise it opens in the current tab when that one is empty, or in a new tab.
- At launch the most recent conversation is reopened in a single tab, as before.

## Approaches

- **One harness process per open conversation (chosen)**: `ChatSession` keeps a list of tabs, each with its transcript and model settings, and a harness process per tab that is started on that tab's first message. The harness and its protocol are unchanged; isolation between conversations is the process boundary, and closing a tab is ending its process.
- One harness multiplexing conversations by id: a single Node process, but every protocol message needs a conversation id, per-conversation abort and history, and one provider per conversation inside the process. More protocol and more ways for events to cross conversations, for no user-visible gain.
- Keeping one visible conversation and queueing: does not meet "both replies complete".

## Design

**`ChatSession`** (`native/Sources/AtlasApp/ChatSession.swift`) stays the one object the store owns.

- `tabs: [Tab]` (`id` = conversation id, `transcript`, `settings`) and `conversationID`, the selected tab. `transcript`, `settings`, `hasKey`, and `models` read the selected tab, so the panel's message list, composer, and model menu keep working on "the current conversation".
- Each tab's harness (process, stdin, output buffer, whether it holds the conversation's history) is kept per tab id; events are applied to the tab they were started for.
- `newConversation()` adds a tab that uses the current tab's model, or selects an already empty tab instead of adding a second one. `select(_:)` switches. `close(_:)` ends that tab's harness, ends its reply as stopped (which saves it), and removes the tab; closing the last tab leaves one empty conversation.
- `stopReply()`, `regenerate`, `editLast`, and changing the model act on the selected tab only. Choosing a model restarts only that tab's harness. Saving a provider's key or base URL in *Model settings* restarts the harness of every tab using that provider, since they hold the old value. The provider and model last chosen are still stored as the defaults for the first tab of the next launch.
- `shutdown()` ends every harness.

**Panel** (`ChatPanel.swift`): the header's title becomes a tab strip (tabs share its width, shortening their names, and scroll sideways once they cannot get narrower), followed by *New conversation* (+), *Conversation history*, and *Model settings*. A tab shows the conversation's name (or *New conversation*), a dot while its reply is running, and a close button; the selected tab is raised. The history menu and *New conversation* are no longer disabled while a reply runs. The draft in the input is shared across tabs; an edit of the last message is dropped when the tab changes.

**Harness** (`scripts/agent-chat.mjs`): unchanged.

**Docs**: GLOSSARY (*Conversation tab*), the "Chat panel" section of `docs/macos.md`, light and dark evidence in `docs/evidence/`.

## Tests

Swift (`ChatSessionTests`, with a stand-in harness that records what it receives): two conversations reply side by side in separate processes and neither is given the other's messages; stop only stops the selected conversation; closing a conversation ends its harness, saves it as stopped, and leaves an empty conversation when it was the last; each tab keeps its own model and a new tab starts with the current one; reopening an already open conversation selects its tab; shutdown ends every harness. Localization table checks cover the new string.
