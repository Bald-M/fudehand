import Foundation

/// 对话面板中的一条记录。工具调用和结果也作为记录显示，便于看清 Agent 做了什么。
public struct ChatEntry: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user, assistant, toolCall, toolResult(ok: Bool), error, notice
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    /// 工具参数或结果全文，界面中可展开查看。
    public let detail: String?
}

/// 把 Agent harness 输出的 JSON 行（见 scripts/agent-chat.mjs）整理成对话记录。
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

    /// harness 意外退出等无法由事件表达的失败。
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

    /// 不打断回复状态的提示，例如切换了模型设置。
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
