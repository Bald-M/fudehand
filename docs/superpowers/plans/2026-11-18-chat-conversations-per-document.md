# Chat Conversations Per Design Document Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each project file has its own saved conversations; opening it restores the open tabs, their messages, and each conversation's model.

**Architecture:** `ChatHistory` stays "the conversations in one directory" and learns the per-document directory layout and the open-tab list. `ChatSession` restores its tabs from the history it is given and can be handed another one (`show`) or told to take its conversations along (`rebind`). `FudehandStore` picks the history from the document's file path.

**Tech Stack:** Swift 5 mode (FudehandCore, FudehandApp, swift-testing), CryptoKit for the path hash.

**Spec:** `docs/superpowers/specs/2026-11-18-chat-conversations-per-document-design.md`

## Global Constraints

- Root: `~/Library/Application Support/fudehand/chats`; per document `documents/<SHA-256 hex of the symlink-resolved path>/`; untitled document `unsaved/`; open tabs in `tabs.json`.
- Saved data holds provider and model only: no API key, no base URL. Nothing is written to the `.fudehand` file.
- Unreadable data never throws to the UI: it is skipped.
- Comments, test names in English. No new UI copy. No new dependencies. Only touch what the feature needs.

## Review Focus

- `tabs.json` lists a conversation whose file is gone or damaged — the other tabs still open (Task 1/2).
- A saved provider that this build does not know — the conversation opens with the current settings (Task 2).
- A reply is running when the document is replaced — the conversation stays open and is saved with the new document; the old one keeps it as it was (Task 2).
- Save As onto a file that already has conversations — both sets are listed afterwards (Task 1).
- A second untitled document after an unsaved one — none of the first one's conversations appear (Task 3).

---

### Task 1: `ChatHistory` per document

**Files:** Modify `native/Sources/FudehandCore/ChatHistory.swift`; test `native/Tests/FudehandCoreTests/ChatHistoryTests.swift`.

**Produces:**
- `ChatConversation.provider: String?`, `.model: String?`; `init(id:transcript:updatedAt:provider:model:)` with both defaulting to nil.
- `ChatHistory.OpenTabs { ids: [UUID]; selected: UUID? }` (Codable, Equatable), `openTabs() -> OpenTabs?`, `saveOpenTabs(_:) throws`.
- `static func document(path: String, root: URL, limit: Int = 50) -> ChatHistory`, `static func unsaved(root: URL) -> ChatHistory`.
- `func adopt(_ other: ChatHistory)` — copies the other directory's files that this one does not have; `func remove()` — deletes the directory.

- [ ] Tests: `chatHistoryKeepsEachDocumentsConversationsApart` (two paths → different directories under `documents/`, same path → same directory, neither lists the other's conversation, directory name does not contain the file name); `chatHistorySavesTheOpenTabsAndTheModel` (round trip of `OpenTabs` and of provider/model; a conversation JSON without the fields decodes with nil; damaged `tabs.json` → nil; `tabs.json` is not listed as a conversation); `chatHistoryAdoptsAnotherDocumentsConversations` (destination keeps its own, gains the others; `remove()` empties the source).
- [ ] Run `swift test --package-path native --filter FudehandCoreTests.chatHistory` through `scripts/native-swift.mjs` conventions (`pnpm test:native -- --filter …`), see them fail, implement, see them pass.
- [ ] Commit.

### Task 2: `ChatSession` restores tabs, switches and rebinds

**Files:** Modify `native/Sources/FudehandApp/ChatSession.swift`; test `native/Tests/FudehandAppTests/ChatSessionTests.swift`.

**Consumes:** Task 1. **Produces:** `func show(_ next: ChatHistory?, fresh: Bool = false)` (fresh empties `next` before restoring), `func rebind(to next: ChatHistory, moving: Bool)`.

- [ ] Tests:
  - `chatTabsAndTheirModelsAreRestoredAfterARelaunch`: two conversations, the second switched to provider `openai` model `gpt-x`, first selected; a new session on the same history has both tabs in order with their settings (base URL from defaults) and the same selection; after closing one and relaunching, only the other is a tab but both are in `conversations`. The saved files contain neither the test key nor the base URL.
  - `chatRestoreSkipsUnreadableConversations`: `tabs.json` naming a missing id and a damaged file plus one good conversation → one tab; a saved provider `"gone"` → current settings; damaged `tabs.json` and no conversations → one empty tab.
  - `chatShowsTheConversationsOfTheDocumentShown`: send in A, `show(B)` → empty conversation and empty list; send in B; `show(A)` → A's tab back; `show(unsaved, fresh: true)` twice does not bring back what the first untitled document had.
  - `chatReplyRunningWhenTheDocumentChangesMovesWithIt` (stand-in harness that never answers): `show(B)` keeps the busy tab selected and busy, `B.list()` has it, and `A` keeps it as it was.
  - `chatConversationsFollowTheDocumentWhenItIsSaved`: `rebind(to: B, moving: true)` → B lists them, the source directory is gone, later sends save to B; `moving: false` → both list them.
- [ ] Implement: `history` becomes a `var`; restoring is one function used by `init` and `show`; `tabs`/`conversationID` `didSet` write `tabs.json` only when the open ids or selection changed; `save` passes provider and model; the `settings` setter and `store(_:)` save the conversations they change.
- [ ] Run `ChatSessionTests`, commit.

### Task 3: `FudehandStore` picks the history from the file path

**Files:** Modify `native/Sources/FudehandApp/FudehandStore.swift`, `native/Sources/FudehandApp/FudehandApp.swift` (`chatRoot: ChatSession.savedRoot`), existing callers of `chatHistory:`; test `native/Tests/FudehandAppTests/StoreTests.swift`.

**Produces:** `FudehandStore.init(defaults:chatRoot: URL? = nil)`; `replace` calls `chat.show`, `write(to:)` calls `chat.rebind` (moving when there was no file).

- [ ] Test `storeBindsConversationsToTheDocument`: with a temporary root — send in an untitled document, `write(to: a)`, `replace(DesignDocument(), url: nil)` → empty panel; `open(a)` → the conversation is back; `write(to: b)` (Save As) then `open(a)` → still there; a new store on the same root (relaunch) after an unsaved conversation shows nothing from it, and `open(a)` restores A's tab.
- [ ] Implement, run `StoreTests`, commit.

### Task 4: Documentation

- [ ] `docs/macos.md` (the *Conversations* bullet: where conversations are saved, what opening a document restores, unsaved documents, a running reply moving with the document), `GLOSSARY.md` (*Conversation*: belongs to a design document's project file), `CHANGELOG.md` if it lists unreleased changes.
- [ ] Full gate: `pnpm test:native`, `pnpm check`; check the real app (two documents, relaunch) in light and dark; commit.
