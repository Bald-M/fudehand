# Chat Conversations Per Design Document Design

Issue: #102.

## Intent

A conversation with the Agent is about one design document. Reopening that document should bring back the conversations held about it — the open tabs, their messages, and the model each one uses — and a different document should not show them.

Conversations are already saved on this Mac (`ChatHistory`, one JSON file each), but in one global list: every document shows the same history, and a relaunch reopens only the most recent conversation, in a single tab, with the model stored last.

## Goals, non-goals, anti-goals

- **Goals**: each project file has its own conversations, found by the file's path; opening a document restores its open conversation tabs in order, the selected one, their messages (tool calls and results included), and each conversation's provider and model; a document that was never saved keeps its conversations for as long as it is open and takes them along on its first save.
- **Non-goals**: cloud sync or search; finding the conversations of a file that was moved or renamed; resuming a reply that was running at quit (it is kept as stopped, as today); migrating the conversations saved in the old global list.
- **Anti-goals**: anything about conversations in the `.fudehand` file or the repository; an API key or base URL in the saved data; a crash or a blocked launch because saved data cannot be read.

## Approaches

- **One directory per document, named by a hash of its path (chosen)**: reuses `ChatHistory` as it is — the session is simply handed a different directory when the document changes. The path never appears in a file name, and a path of any length or character set works.
- One index file mapping paths to conversation ids over the existing flat directory: every list and prune would have to filter through the index, and a damaged index would detach every conversation at once.
- Storing conversations beside the project file (`Design.fudehand.chats/`): survives moves, but puts the data in the user's repository, which the issue rules out.

## Design

**Storage** (`FudehandCore/ChatHistory.swift`). Under the root `~/Library/Application Support/fudehand/chats`:

- `documents/<SHA-256 hex of the file's canonical path>/` (symlinks resolved, and the name as spelled on disk) — the conversations of that project file: `<conversation id>.json` each, and `tabs.json` with the ids of the open tabs in order and the selected one. The 50 most recent conversations per document are kept.
- `unsaved/` — the same, for the document that has no file yet. Emptied when the App launches and whenever another untitled document replaces the current one.
- A conversation's JSON gains optional `provider` and `model`. The base URL is not saved: it belongs to the provider's settings, and is read from there when the conversation is restored. Files without the fields load with the settings in use.
- The JSON files saved directly in the root by earlier versions are left where they are and no longer shown.

**Restoring** (`FudehandApp/ChatSession.swift`). The tabs listed in `tabs.json` are reopened in order, skipping conversations that cannot be read; a conversation whose saved provider is unknown uses the current settings. With no readable `tabs.json`, the most recent conversation is reopened in one tab (as before); with nothing to reopen, the panel starts with one empty conversation. Closing a tab removes it from `tabs.json`, so it does not come back as a tab; it stays in the *Conversation history* menu. `tabs.json` is rewritten whenever the list of open, non-empty conversations or the selection changes; a conversation is also saved when its model changes.

**Switching documents** (`FudehandStore.replace` → `ChatSession.show`). New, Open, a template, and the Agent's document commands all replace the document, and the panel then shows the new document's conversations. Harnesses of idle conversations are ended. A conversation whose reply is running stays open with its harness untouched and is saved with the new document from then on, because the reply is what is acting on the document now shown: an Agent told to "open that file and change it" would otherwise cut off its own reply. The old document keeps the conversation as it was at that moment, so nothing said about it is lost when the new document is an untitled one that is never saved, or when the running reply belonged to another tab than the one that replaced the document.

**Saving the document** (`FudehandStore.write` → `ChatSession.rebind`). The first save of an untitled document moves its conversations to the file's directory. Save As to another path copies them there and the original file keeps its own. Conversations the destination already has are kept, except that an open conversation replaces an older copy of itself. Running replies are not interrupted.

**Failure handling**. Unreadable conversation files and an unreadable `tabs.json` are skipped; failed writes are ignored, as they already are — the conversation stays usable in memory.

## Left to the builder

Names of the new functions, and how the tests arrange their temporary directories.
