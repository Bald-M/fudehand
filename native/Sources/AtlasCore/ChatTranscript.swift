import Foundation

/// A layer that was selected when a chat message was sent; shown as a context tag and passed to the Agent with the message.
public struct ChatContext: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String

    public init(id: String, name: String, type: String) {
        self.id = id
        self.name = name
        self.type = type
    }
}

/// One entry in the chat panel. A tool call and its result are one entry, making it clear what the Agent did.
public struct ChatEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, tool, error, notice
    }

    public enum ToolStatus: String, Codable, Sendable {
        case running, succeeded, failed
    }

    public let id: Int
    public let kind: Kind
    /// The message text; for a tool entry, the tool's name.
    public fileprivate(set) var text: String
    /// Only for tool entries.
    public fileprivate(set) var status: ToolStatus?
    /// The tool arguments as JSON, which can be expanded in the UI.
    public fileprivate(set) var detail: String?
    /// The text of the tool result, which can be expanded in the UI.
    public fileprivate(set) var result: String?
    /// The layers selected when a user message was sent.
    public fileprivate(set) var context: [ChatContext] = []
    /// The harness's id of a tool call, matching the result to its call.
    fileprivate var call: String?

    /// What a tool call acts on, for the card's title: the layer names (looked up by id), the file name, or the zoom level.
    public static func toolSubject(arguments: String?, layerName: (String) -> String?) -> String? {
        guard let arguments, let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] else { return nil }
        if let name = (args["node"] as? [String: Any])?["name"] as? String, !name.isEmpty { return name }
        let ids = (args["id"] as? String).map { [$0] } ?? args["ids"] as? [String] ?? []
        let names = ids.compactMap(layerName)
        if !names.isEmpty { return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "") }
        if let path = args["path"] as? String, !path.isEmpty { return (path as NSString).lastPathComponent }
        if let scale = args["scale"] as? Double { return "\(Int((scale * 100).rounded()))%" }
        return nil
    }
}

/// Entries shown together: a single entry, or a run of consecutive tool calls that the UI can fold into "N steps".
public struct ChatGroup: Equatable, Identifiable, Sendable {
    public let entries: [ChatEntry]
    /// The id of the first entry, which stays the same while later calls join the run.
    public var id: Int { entries[0].id }
    public var isSteps: Bool { entries.count > 1 }
}

/// Turns the JSON lines output by the Agent harness (see scripts/agent-chat.mjs) into the chat transcript.
public struct ChatTranscript: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    public private(set) var busy = false
    private var nextID = 0
    /// Whether the last entry is assistant text that is still streaming in.
    private var streaming = false

    public init() {}

    /// Restores a saved conversation. Nothing is running any more, so a call that was saved while in progress counts as failed.
    public init(entries: [ChatEntry]) {
        self.entries = entries
        nextID = (entries.map(\.id).max() ?? -1) + 1
        settle()
    }

    public mutating func send(_ text: String, context: [ChatContext] = []) {
        append(.user, text)
        entries[entries.count - 1].context = context
        busy = true
    }

    public mutating func apply(_ line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = event["type"] as? String else { return }
        let name = event["name"] as? String ?? ""
        let text = event["text"] as? String ?? ""
        switch type {
        case "assistant_delta":
            if streaming { entries[entries.count - 1].text += text } else { append(.assistant, text); streaming = true }
        case "assistant":
            // The complete text of the round replaces what was streamed.
            if streaming { entries[entries.count - 1].text = text; streaming = false } else { append(.assistant, text) }
        case "tool_call":
            let args = event["args"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
            append(.tool, name)
            entries[entries.count - 1].status = .running
            entries[entries.count - 1].detail = args.map { String(decoding: $0, as: UTF8.self) }
            entries[entries.count - 1].call = event["id"] as? String
        case "tool_result":
            let status: ChatEntry.ToolStatus = event["ok"] as? Bool == true ? .succeeded : .failed
            let call = event["id"] as? String
            var index = entries.lastIndex { $0.status == .running && $0.call == call }
            if index == nil { append(.tool, name); index = entries.count - 1 }
            entries[index!].status = status
            entries[index!].result = text
        case "error":
            append(.error, event["message"] as? String ?? L("Unknown error"))
        case "done":
            if event["stopped"] as? Bool == true { stop() } else { busy = false; settle() }
        default:
            return
        }
    }

    /// Failures that events cannot express, such as the harness exiting unexpectedly.
    public mutating func fail(_ message: String) {
        append(.error, message)
        busy = false
        settle()
    }

    /// Ends the running reply as stopped, keeping the text received so far; also used when the harness is terminated before it can report `done`.
    public mutating func stop() {
        guard busy else { return }
        busy = false
        settle()
        append(.notice, L("Reply stopped"))
    }

    /// Removes the last user message and everything after it, returning that message so it can be sent again or edited. Nothing happens while a reply is running.
    public mutating func rewind() -> ChatEntry? {
        guard !busy, let index = entries.lastIndex(where: { $0.kind == .user }) else { return nil }
        let removed = entries[index]
        entries.removeSubrange(index...)
        return removed
    }

    public var lastUserID: Int? { entries.last { $0.kind == .user }?.id }

    /// The user and assistant texts, in the form the harness's `load` message takes to restore its history.
    public var messages: [[String: String]] {
        entries.filter { ($0.kind == .user || $0.kind == .assistant) && !$0.text.isEmpty }.map { ["role": $0.kind.rawValue, "text": $0.text] }
    }

    /// The first line of the first user message, shortened, as the conversation's name in the history menu.
    public var title: String {
        let line = entries.first { $0.kind == .user }?.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        return line.count > 50 ? "\(line.prefix(50))…" : line
    }

    public var groups: [ChatGroup] {
        var groups: [[ChatEntry]] = []
        for entry in entries {
            if entry.kind == .tool, groups.last?.last?.kind == .tool { groups[groups.count - 1].append(entry) } else { groups.append([entry]) }
        }
        return groups.map(ChatGroup.init)
    }

    /// Ends any streaming text, and marks calls that never got a result as failed.
    private mutating func settle() {
        streaming = false
        for index in entries.indices where entries[index].status == .running { entries[index].status = .failed }
    }

    private mutating func append(_ kind: ChatEntry.Kind, _ text: String) {
        streaming = false
        entries.append(ChatEntry(id: nextID, kind: kind, text: text))
        nextID += 1
    }
}

/// Whether the chat panel keeps scrolling to the newest text. It follows until the user scrolls up, and again once they are back at the bottom.
public struct ChatScrollFollow: Equatable, Sendable {
    public private(set) var following = true
    /// Whether the newest text is in view right now; false after content grew below the view, even while still following.
    public private(set) var atBottom = true
    private var offset = 0.0

    public init() {}

    /// `offset` is how far the content has been scrolled. Content growing below the view does not stop following; only scrolling up does.
    public mutating func update(offset: Double, contentHeight: Double, viewportHeight: Double, tolerance: Double = 24) {
        atBottom = contentHeight - offset - viewportHeight <= tolerance
        if atBottom { following = true } else if offset < self.offset - 1 { following = false }
        self.offset = offset
    }
}
