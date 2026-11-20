import Foundation
import Testing
@testable import FudehandApp
@testable import FudehandCore

/// A stand-in harness that records what the App sends it. It answers a user message with "ok", except "ask", which asks a question
/// and continues once it is answered, and "hang", which only a stop ends; a compaction ends with a summary.
private func harness() throws -> (root: URL, received: () throws -> [[String: Any]]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let script = """
    import { createInterface } from 'node:readline'
    import { appendFileSync } from 'node:fs'
    const emit = event => process.stdout.write(JSON.stringify(event) + '\\n')
    const input = createInterface({ input: process.stdin })
    input.on('line', line => {
      const message = JSON.parse(line)
      appendFileSync(new URL('../received.jsonl', import.meta.url), JSON.stringify({ ...message, caller: process.env.FUDEHAND_CONVERSATION }) + '\\n')
      if (message.type === 'user' && message.text === 'ask') emit({ type: 'question', id: 'q1', question: 'Which theme?', options: [{ label: 'Dark' }, { label: 'Light' }] })
      else if (message.type === 'user' && message.text !== 'hang') { emit({ type: 'assistant', text: 'ok' }); emit({ type: 'done', stopped: false }) }
      if (message.type === 'answer') { emit({ type: 'assistant', text: 'answered' }); emit({ type: 'done', stopped: false }) }
      if (message.type === 'compact') { emit({ type: 'compacted', summary: 'summary' }); emit({ type: 'done', stopped: false }) }
      if (message.type === 'stop') emit({ type: 'done', stopped: true })
    })
    input.on('close', () => process.exit(0))
    """
    try script.write(to: root.appendingPathComponent("scripts/agent-chat.mjs"), atomically: true, encoding: .utf8)
    return (root, {
        guard let text = try? String(contentsOf: root.appendingPathComponent("received.jsonl"), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    })
}

@MainActor private func makeStore(root: URL?) -> (FudehandStore, ChatHistory) {
    let history = ChatHistory(directory: FileManager.default.temporaryDirectory.appendingPathComponent("fudehand-chats-\(UUID().uuidString)"))
    let defaults = UserDefaults(suiteName: "fudehand-tests-\(UUID().uuidString)")!
    let store = FudehandStore(defaults: defaults, chat: ChatSession(defaults: defaults, readKey: { _ in nil }, history: history))
    store.toolsRoot = root
    return (store, history)
}

@MainActor private func control(_ store: FudehandStore, _ command: ControlCommand, caller: UUID? = nil) async throws -> [String: Any] {
    try #require(try await store.handleControl(command, caller: caller) as? [String: Any])
}

@MainActor private func failure(_ store: FudehandStore, _ command: ControlCommand, caller: UUID? = nil) async -> String? {
    do { _ = try await store.handleControl(command, caller: caller); return nil } catch { return error.localizedDescription }
}

/// Waits until the selected conversation's reply has ended.
@MainActor private func settle(_ store: FudehandStore) async throws {
    for _ in 0..<100 where store.chat.transcript.busy && !store.chat.transcript.waiting { try await Task.sleep(nanoseconds: 50_000_000) }
}

@MainActor private func texts(_ conversation: [String: Any]) -> [String] {
    (conversation["entries"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
}

@Test func chatHarnessIsToldWhichConversationItServes() {
    let id = UUID()
    let launch = ChatSession.launch(root: URL(fileURLWithPath: "/repo"), runtime: nil, settings: ChatSettings(provider: "deepseek", model: "", baseUrl: ""),
                                    apiKey: nil, environment: ["FUDEHAND_CONVERSATION": "stale"], conversation: id)
    #expect(launch.environment["FUDEHAND_CONVERSATION"] == id.uuidString)
    let listing = ChatSession.launch(root: URL(fileURLWithPath: "/repo"), runtime: nil, settings: ChatSettings(provider: "deepseek", model: "", baseUrl: ""),
                                     apiKey: nil, environment: ["FUDEHAND_CONVERSATION": "stale"], listModels: true)
    #expect(listing.environment["FUDEHAND_CONVERSATION"] == nil)
}

@Test @MainActor func agentSendsMessagesWithContextAndModesAsThePanelDoes() async throws {
    let fake = try harness()
    defer { try? FileManager.default.removeItem(at: fake.root) }
    let (store, history) = makeStore(root: fake.root)
    defer { try? FileManager.default.removeItem(at: history.directory) }
    _ = try await store.handleControl(.createNode(parent: nil, index: nil, node: JSONObject(["id": "hero", "type": "frame", "name": "Hero"])))
    let first = store.chat.conversationID

    let sent = try await control(store, .sendMessage(nil, text: "Make it blue", context: ["hero"], mode: .plan))
    #expect(sent["id"] as? String == first.uuidString)
    #expect(sent["mode"] as? String == "plan")
    try await settle(store)
    var conversation = try await control(store, .getConversation(first))
    #expect(texts(conversation) == ["Make it blue", "ok"])
    #expect(conversation["planReady"] as? Bool == true)
    #expect((conversation["entries"] as? [[String: Any]])?.first?["context"] as? [[String: String]] == [["id": "hero", "name": "Hero", "type": "frame"]])

    // Run Plan leaves plan mode and asks for the plan to be carried out.
    conversation = try await control(store, .runPlan(nil, context: []))
    #expect(conversation["mode"] is NSNull && conversation["planReady"] as? Bool == false)
    try await settle(store)
    #expect(await failure(store, .runPlan(nil, context: [])) == "The conversation has no plan waiting to be confirmed; plan mode makes one")
    // Entering and leaving a mode, as the mode tag does; then editing the last message and regenerating the reply.
    #expect(try await control(store, .setMode(nil, mode: .goal))["mode"] as? String == "goal")
    #expect(try await control(store, .setMode(nil, mode: nil))["mode"] is NSNull)
    _ = try await control(store, .editLastMessage(nil, text: "Make it red", context: []))
    try await settle(store)
    _ = try await control(store, .regenerateReply(nil))
    try await settle(store)
    conversation = try await control(store, .compactConversation(nil))
    #expect(conversation["compacting"] as? Bool == true)
    try await settle(store)
    #expect(texts(try await control(store, .getConversation(nil))) == ["Make it blue", "ok", "Make it red", "ok", "summary"])
    await store.chat.shutdown()

    let received = try fake.received()
    #expect(received.map { $0["type"] as? String } == ["load", "user", "user", "load", "user", "load", "user", "compact"])
    #expect(received[1]["mode"] as? String == "plan")
    #expect((received[1]["context"] as? [[String: String]]) == [["id": "hero", "name": "Hero", "type": "frame"]])
    #expect(received[2]["text"] as? String == "Carry out the plan." && received[2]["mode"] == nil)
    #expect(received[4]["text"] as? String == "Make it red" && received[4]["mode"] == nil)
    #expect(received[6]["text"] as? String == "Make it red")
    #expect(received.allSatisfy { $0["caller"] as? String == first.uuidString })
}

@Test @MainActor func agentReadsAndAnswersAQuestionCard() async throws {
    let fake = try harness()
    defer { try? FileManager.default.removeItem(at: fake.root) }
    let (store, history) = makeStore(root: fake.root)
    defer { try? FileManager.default.removeItem(at: history.directory) }
    _ = try await control(store, .sendMessage(nil, text: "ask", context: [], mode: nil))
    for _ in 0..<100 where !store.chat.transcript.waiting { try await Task.sleep(nanoseconds: 50_000_000) }
    let waiting = try await control(store, .getConversation(nil))
    #expect(waiting["waiting"] as? Bool == true)
    let card = try #require((waiting["entries"] as? [[String: Any]])?.last)
    #expect(card["kind"] as? String == "question" && card["text"] as? String == "Which theme?")
    let question = try #require(card["question"] as? [String: Any])
    #expect(question["state"] as? String == "pending")
    #expect((question["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } == ["Dark", "Light"])

    // A new message is refused while the question waits.
    #expect(await failure(store, .sendMessage(nil, text: "hello", context: [], mode: nil))?.contains("chat_answer_question") == true)
    _ = try await control(store, .answerQuestion(nil, answer: "Dark"))
    try await settle(store)
    let answered = try await control(store, .getConversation(nil))
    #expect(texts(answered) == ["ask", "Which theme?", "answered"])
    #expect(((answered["entries"] as? [[String: Any]])?[1]["question"] as? [String: Any])?["answer"] as? String == "Dark")
    #expect(await failure(store, .answerQuestion(nil, answer: nil)) == "The conversation has no question waiting for an answer")
    await store.chat.shutdown()
    #expect(try fake.received().last?["text"] as? String == "Dark")
}

@Test @MainActor func agentManagesConversationTabsAsThePanelDoes() async throws {
    let fake = try harness()
    defer { try? FileManager.default.removeItem(at: fake.root) }
    let (store, history) = makeStore(root: fake.root)
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let first = store.chat.conversationID
    _ = try await control(store, .sendMessage(nil, text: "First chat", context: [], mode: nil))
    try await settle(store)

    var list = try await control(store, .newConversation)
    let second = try #require(UUID(uuidString: list["selected"] as? String ?? ""))
    #expect(second != first && store.chat.conversationID == second)
    #expect((list["tabs"] as? [[String: Any]])?.count == 2)
    _ = try await control(store, .sendMessage(nil, text: "Second chat", context: [], mode: nil))
    try await settle(store)
    list = try await control(store, .listConversations)
    #expect((list["saved"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["Second chat", "First chat"])
    #expect((list["tabs"] as? [[String: Any]])?.compactMap { $0["entryCount"] as? Int } == [2, 2])

    // Closing a tab keeps the conversation in the history, where it can be read and reopened.
    list = try await control(store, .closeConversation(first))
    #expect((list["tabs"] as? [[String: Any]])?.count == 1)
    #expect((list["saved"] as? [[String: Any]])?.first { $0["id"] as? String == first.uuidString }?["open"] as? Bool == false)
    let saved = try await control(store, .getConversation(first))
    #expect(saved["open"] as? Bool == false && texts(saved) == ["First chat", "ok"])
    #expect(await failure(store, .sendMessage(first, text: "Hi", context: [], mode: nil))?.hasPrefix("Conversation is not open") == true)
    _ = try await control(store, .openConversation(first))
    #expect(store.chat.conversationID == first && store.chat.tabs.count == 2)

    // Clearing empties it in place; deleting removes it from the history and closes its tab.
    let cleared = try await control(store, .clearConversation(second))
    #expect(texts(cleared).isEmpty && store.chat.conversationID == second)
    #expect(await failure(store, .deleteConversation(second)) == "The conversation is empty; there is nothing to delete")
    list = try await control(store, .deleteConversation(first))
    #expect((list["saved"] as? [[String: Any]])?.isEmpty == true)
    #expect(store.chat.tabs.map(\.id) == [second])
    #expect(await failure(store, .openConversation(first)) == "Conversation not found: \(first.uuidString)")
    #expect(await failure(store, .closeConversation(second)) == "This is the only conversation and it is empty; there is nothing to close")
    await store.chat.shutdown()
}

@Test @MainActor func agentCannotStopDeleteOrReconfigureItsOwnConversation() async throws {
    let fake = try harness()
    defer { try? FileManager.default.removeItem(at: fake.root) }
    let (store, history) = makeStore(root: fake.root)
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let own = store.chat.conversationID
    _ = try await control(store, .sendMessage(nil, text: "hang", context: [], mode: nil))
    let refused: [ControlCommand] = [
        .stopReply(nil), .stopReply(own), .closeConversation(own), .deleteConversation(own), .clearConversation(nil),
        .setMode(nil, mode: .goal), .runPlan(nil, context: []), .sendMessage(nil, text: "Hi", context: [], mode: nil), .regenerateReply(nil),
        .editLastMessage(nil, text: "Hi", context: []), .answerQuestion(nil, answer: "Dark"), .compactConversation(nil),
    ]
    for command in refused {
        #expect(await failure(store, command, caller: own)?.hasPrefix("A conversation cannot") == true, "\(command)")
    }
    #expect(store.chat.transcript.busy && store.chat.mode == nil && store.chat.tabs.count == 1)
    // Reading it is allowed, and another conversation may be started and used.
    #expect(try await control(store, .getConversation(nil), caller: own)["busy"] as? Bool == true)
    _ = try await control(store, .newConversation, caller: own)
    _ = try await control(store, .setMode(nil, mode: .goal), caller: own)
    #expect(store.chat.mode == .goal)

    // Anyone else can stop it.
    _ = try await control(store, .stopReply(own))
    for _ in 0..<100 where store.chat.tabs.first(where: { $0.id == own })?.transcript.busy == true { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(store.chat.tabs.first { $0.id == own }?.transcript.entries.last?.kind == .notice)
    await store.chat.shutdown()
}

@Test @MainActor func chatCommandsExplainWhyTheyCannotRun() async throws {
    let (store, history) = makeStore(root: nil)
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let missing = UUID()
    #expect(await failure(store, .getConversation(missing)) == "Conversation not found: \(missing.uuidString)")
    #expect(await failure(store, .openConversation(missing)) == "Conversation not found: \(missing.uuidString)")
    #expect(await failure(store, .stopReply(nil)) == "The conversation is not replying")
    #expect(await failure(store, .regenerateReply(nil)) == "The conversation has no message to regenerate a reply to")
    #expect(await failure(store, .editLastMessage(nil, text: "Hi", context: [])) == "The conversation has no message to edit")
    #expect(await failure(store, .compactConversation(nil)) == "There is nothing to compact yet")
    #expect(await failure(store, .sendMessage(nil, text: "Hi", context: ["nope"], mode: nil)) == "Layer not found: nope")
    #expect(await failure(store, .sendMessage(nil, text: "Hi", context: [], mode: nil))
            == "Cannot find the Fudehand source directory, so the chat process cannot start")
    // Nothing was sent or switched by the refused commands.
    #expect(store.chat.transcript.entries.isEmpty && store.chat.mode == nil)
}

@Test @MainActor func deletingAClosedConversationLeavesTheTabsAsTheyWere() async throws {
    let fake = try harness()
    defer { try? FileManager.default.removeItem(at: fake.root) }
    let (store, history) = makeStore(root: fake.root)
    defer { try? FileManager.default.removeItem(at: history.directory) }
    let closed = store.chat.conversationID
    _ = try await control(store, .sendMessage(nil, text: "Old chat", context: [], mode: nil))
    try await settle(store)
    _ = try await control(store, .newConversation)
    _ = try await control(store, .sendMessage(nil, text: "Kept chat", context: [], mode: nil))
    try await settle(store)
    _ = try await control(store, .closeConversation(closed))
    _ = try await control(store, .newConversation)
    let tabs = store.chat.tabs.map(\.id)
    let selected = store.chat.conversationID

    let list = try await control(store, .deleteConversation(closed))
    #expect(store.chat.tabs.map(\.id) == tabs && store.chat.conversationID == selected)
    #expect((list["saved"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["Kept chat"])
    await store.chat.shutdown()
}
