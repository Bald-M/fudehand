import FudehandCore
import Foundation

/// The `chat_*` control commands: they act on the chat panel's conversations through the same `ChatSession` methods the panel calls,
/// selecting the conversation's tab first as a person would. A command cannot stop, delete, or reconfigure the conversation whose
/// Agent sent it (`caller`).
extension FudehandStore {
    func handleChatControl(_ command: ControlCommand, caller: UUID?) throws -> Any {
        switch command {
        case .listConversations:
            return chatList()
        case .getConversation(let id):
            let id = id ?? chat.conversationID
            if let tab = chat.tabs.first(where: { $0.id == id }) { return conversationJSON(tab) }
            guard let saved = chat.saved(id) else { throw ControlCommandError("Conversation not found: \(id.uuidString)") }
            return conversationJSON(saved)
        case .openConversation(let id):
            guard chat.tabs.contains(where: { $0.id == id }) || chat.saved(id) != nil else {
                throw ControlCommandError("Conversation not found: \(id.uuidString)")
            }
            chat.open(id)
            return chatList()
        case .newConversation:
            chat.newConversation()
            return chatList()
        case .closeConversation(let id):
            let tab = try openTab(id, caller: caller, action: "close")
            if chat.tabs.count == 1, tab.transcript.entries.isEmpty {
                throw ControlCommandError("This is the only conversation and it is empty; there is nothing to close")
            }
            chat.close(id)
            return chatList()
        case .deleteConversation(let id):
            if id == caller { throw ownConversation("delete") }
            if let tab = chat.tabs.first(where: { $0.id == id }) {
                if tab.transcript.busy { throw ControlCommandError("The conversation is replying; stop it with chat_stop_reply before deleting it") }
                if tab.transcript.entries.isEmpty { throw ControlCommandError("The conversation is empty; there is nothing to delete") }
            } else if chat.saved(id) == nil {
                throw ControlCommandError("Conversation not found: \(id.uuidString)")
            }
            chat.deleteConversation(id)
            return chatList()
        case .clearConversation(let id):
            try select(id, caller: caller, action: "clear")
            chat.clearConversation()
            return conversationJSON(chat.tabs.first { $0.id == chat.conversationID }!)
        case .sendMessage(let id, let text, let layers, let mode):
            try select(id, caller: caller, action: "send a message to")
            try requireIdle()
            let context = try chatContext(layers)
            try requireToolsRoot()
            if let mode { chat.mode = mode }
            chat.send(text, context: context, root: toolsRoot, runtime: runtime)
            return selectedConversation()
        case .setMode(let id, let mode):
            try select(id, caller: caller, action: "change the mode of")
            chat.mode = mode
            return selectedConversation()
        case .runPlan(let id, let layers):
            try select(id, caller: caller, action: "run the plan of")
            try requireIdle()
            guard chat.planReady else { throw ControlCommandError("The conversation has no plan waiting to be confirmed; plan mode makes one") }
            let context = try chatContext(layers)
            try requireToolsRoot()
            chat.runPlan(context: context, root: toolsRoot, runtime: runtime)
            return selectedConversation()
        case .stopReply(let id):
            try select(id, caller: caller, action: "stop")
            guard chat.transcript.busy else { throw ControlCommandError("The conversation is not replying") }
            chat.stopReply()
            return selectedConversation()
        case .regenerateReply(let id):
            try select(id, caller: caller, action: "regenerate the reply of")
            try requireIdle()
            guard chat.transcript.lastUserID != nil else { throw ControlCommandError("The conversation has no message to regenerate a reply to") }
            try requireToolsRoot()
            chat.regenerate(root: toolsRoot, runtime: runtime)
            return selectedConversation()
        case .editLastMessage(let id, let text, let layers):
            try select(id, caller: caller, action: "edit the last message of")
            // As in the panel, a question left open by a reply that has ended is replaced along with the turn that asked it.
            try requireIdle(allowingQuestion: true)
            guard chat.transcript.lastUserID != nil else { throw ControlCommandError("The conversation has no message to edit") }
            let context = try chatContext(layers)
            try requireToolsRoot()
            // The panel's edit: the last message and its reply come out, and the new text is sent in their place.
            _ = chat.editLast()
            chat.send(text, context: context, root: toolsRoot, runtime: runtime)
            return selectedConversation()
        case .answerQuestion(let id, let answer):
            try select(id, caller: caller, action: "answer the question of")
            guard chat.transcript.waiting else { throw ControlCommandError("The conversation has no question waiting for an answer") }
            try requireToolsRoot()
            chat.answer(answer, root: toolsRoot, runtime: runtime)
            return selectedConversation()
        case .compactConversation(let id):
            try select(id, caller: caller, action: "compact")
            try requireIdle(allowingQuestion: true)
            guard chat.transcript.canCompact else { throw ControlCommandError("There is nothing to compact yet") }
            try requireToolsRoot()
            chat.compact(root: toolsRoot, runtime: runtime)
            return selectedConversation()
        default:
            throw ControlCommandError("Not a chat command")
        }
    }

    private func ownConversation(_ action: String) -> ControlCommandError {
        ControlCommandError("A conversation cannot \(action) itself; this command was sent by the Agent of that conversation")
    }

    /// The open conversation `id`, refused when it is the caller's own.
    private func openTab(_ id: UUID, caller: UUID?, action: String) throws -> ChatSession.Tab {
        if id == caller { throw ownConversation(action) }
        guard let tab = chat.tabs.first(where: { $0.id == id }) else {
            throw ControlCommandError(chat.saved(id) == nil ? "Conversation not found: \(id.uuidString)"
                : "Conversation is not open: \(id.uuidString); open it with chat_open_conversation first")
        }
        return tab
    }

    /// Selects the open conversation `id` (nil: the selected one), as clicking its tab does, so the panel's methods act on it.
    private func select(_ id: UUID?, caller: UUID?, action: String) throws {
        let id = id ?? chat.conversationID
        _ = try openTab(id, caller: caller, action: action)
        chat.select(id)
    }

    /// `allowingQuestion` lets a command run while a question waits on a reply that has already ended (after a relaunch).
    private func requireIdle(allowingQuestion: Bool = false) throws {
        // A reply paused on a question is still running; what it needs is the answer.
        if chat.transcript.waiting, !(allowingQuestion && !chat.transcript.busy) { throw ControlCommandError("The conversation is waiting for an answer to its question; answer it with chat_answer_question") }
        if chat.transcript.busy { throw ControlCommandError("The conversation is still replying; wait for the reply or stop it with chat_stop_reply") }
    }

    private func requireToolsRoot() throws {
        if toolsRoot == nil { throw ControlCommandError("Cannot find the Fudehand source directory, so the chat process cannot start") }
    }

    /// The context tags for layer ids, named as the panel names the selected layers.
    private func chatContext(_ ids: [String]) throws -> [ChatContext] {
        try ids.map { id in
            guard let node = editor.document.node(id) else { throw ControlCommandError("Layer not found: \(id)") }
            return ChatContext(id: node.id, name: node.name, type: node.type.rawValue)
        }
    }

    private func chatList() -> [String: Any] {
        let open = Set(chat.tabs.map(\.id))
        return [
            "selected": chat.conversationID.uuidString,
            "tabs": chat.tabs.map { tab -> [String: Any] in
                var summary = conversationJSON(tab)
                summary.removeValue(forKey: "entries")
                summary["entryCount"] = tab.transcript.entries.count
                return summary
            },
            "saved": chat.conversations.map { ["id": $0.id.uuidString, "title": $0.title,
                                               "updatedAt": ISO8601DateFormatter().string(from: $0.updatedAt), "open": open.contains($0.id)] },
        ]
    }

    private func selectedConversation() -> [String: Any] {
        conversationJSON(chat.tabs.first { $0.id == chat.conversationID }!)
    }

    private func conversationJSON(_ tab: ChatSession.Tab) -> [String: Any] {
        transcriptJSON(id: tab.id, transcript: tab.transcript, provider: tab.settings.provider, model: tab.settings.model).merging([
            "open": true,
            "selected": tab.id == chat.conversationID,
            "busy": tab.transcript.busy,
            "compacting": tab.transcript.compacting,
            "mode": tab.mode?.rawValue ?? NSNull(),
            "planReady": tab.planReady,
        ]) { $1 }
    }

    private func conversationJSON(_ saved: ChatConversation) -> [String: Any] {
        let transcript = ChatTranscript(entries: saved.entries)
        return transcriptJSON(id: saved.id, transcript: transcript, provider: saved.provider, model: saved.model).merging([
            "open": false, "selected": false, "busy": false, "compacting": false, "mode": NSNull(), "planReady": false,
        ]) { $1 }
    }

    private func transcriptJSON(id: UUID, transcript: ChatTranscript, provider: String?, model: String?) -> [String: Any] {
        [
            "id": id.uuidString,
            "title": transcript.title,
            "provider": provider ?? NSNull(),
            // An empty model is the provider's default model.
            "model": model ?? NSNull(),
            "waiting": transcript.waiting,
            // What the context ring shows: the tokens the conversation takes up, as the model API last reported them.
            "contextTokens": transcript.contextTokens ?? NSNull(),
            // The next-message prediction offered in the empty input.
            "suggestion": transcript.suggestion ?? NSNull(),
            "entries": transcript.entries.map(entryJSON),
        ]
    }

    private func entryJSON(_ entry: ChatEntry) -> [String: Any] {
        var object: [String: Any] = ["id": entry.id, "kind": entry.kind.rawValue, "text": entry.text]
        if let status = entry.status { object["status"] = status.rawValue }
        if let detail = entry.detail { object["arguments"] = detail }
        if let result = entry.result { object["result"] = result }
        if !entry.context.isEmpty { object["context"] = entry.context.map { ["id": $0.id, "name": $0.name, "type": $0.type] } }
        if let question = entry.question {
            var card: [String: Any] = [
                "detail": question.detail ?? NSNull(),
                "options": question.options.map { option -> [String: Any] in ["label": option.label, "description": option.description ?? NSNull()] },
            ]
            switch question.state {
            case .pending: card["state"] = "pending"
            case .answered(let answer): card["state"] = "answered"; card["answer"] = answer
            case .skipped: card["state"] = "skipped"
            case .cancelled: card["state"] = "cancelled"
            }
            object["question"] = card
        }
        return object
    }
}
