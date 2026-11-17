import Foundation

/// One entry in the chat panel. Tool calls and results are shown as entries too, making it clear what the Agent did.
public struct ChatEntry: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user, assistant, toolCall, toolResult(ok: Bool), error, notice
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    /// The full text of the tool arguments or result, which can be expanded in the UI.
    public let detail: String?
}

/// Turns the JSON lines output by the Agent harness (see scripts/agent-chat.mjs) into the chat transcript.
public struct ChatTranscript: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    public private(set) var busy = false
    private var nextID = 0

    public init() {}

    public mutating func send(_ text: String) {
        append(.user, text)
        busy = true
    }

    public mutating func apply(_ line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = event["type"] as? String else { return }
        let name = event["name"] as? String ?? ""
        switch type {
        case "assistant":
            append(.assistant, event["text"] as? String ?? "")
        case "tool_call":
            let args = event["args"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
            append(.toolCall, name, detail: args.map { String(decoding: $0, as: UTF8.self) })
        case "tool_result":
            append(.toolResult(ok: event["ok"] as? Bool ?? false), name, detail: event["text"] as? String)
        case "error":
            append(.error, event["message"] as? String ?? L("Unknown error"))
        case "done":
            if event["stopped"] as? Bool == true { stop() } else { busy = false }
        default:
            return
        }
    }

    /// Failures that events cannot express, such as the harness exiting unexpectedly.
    public mutating func fail(_ message: String) {
        append(.error, message)
        busy = false
    }

    /// Ends the running reply as stopped; also used when the harness is terminated before it can report `done`.
    public mutating func stop() {
        guard busy else { return }
        busy = false
        append(.notice, L("Reply stopped"))
    }

    /// A notice that does not interrupt the replying state, for example that the model settings were changed.
    public mutating func note(_ text: String) {
        append(.notice, text)
    }

    public mutating func clear() {
        entries = []
        busy = false
    }

    private mutating func append(_ kind: ChatEntry.Kind, _ text: String, detail: String? = nil) {
        entries.append(ChatEntry(id: nextID, kind: kind, text: text, detail: detail))
        nextID += 1
    }
}
