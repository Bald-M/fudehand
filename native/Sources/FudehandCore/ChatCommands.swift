import Foundation

/// A way of working that a conversation can be switched into from the chat input.
public enum ChatMode: String, CaseIterable, Sendable {
    /// The Agent replies with a plan and changes nothing until the user confirms it.
    case plan
    /// The next message is a goal the Agent keeps working on until it reports it done.
    case goal
}

/// A slash command of the chat input.
public enum ChatCommand: String, CaseIterable, Sendable {
    case plan, goal, new, clear, model

    public var name: String { "/\(rawValue)" }

    /// The mode the command switches the conversation into; nil for a command that acts at once.
    public var mode: ChatMode? {
        switch self {
        case .plan: .plan
        case .goal: .goal
        case .new, .clear, .model: nil
        }
    }
}

/// What the text in the chat input means: a message, or a slash command in one of its stages.
public enum ChatCommandInput: Equatable, Sendable {
    case message
    /// A command name is being typed: the commands whose name starts with it, for the menu.
    case typing([ChatCommand])
    /// A complete command name followed by text.
    case command(ChatCommand, argument: String)
    /// Text after a name that is no command.
    case unknown(String)

    /// Only a slash at the very start of the input makes a command.
    public init(_ draft: String) {
        guard draft.hasPrefix("/") else { self = .message; return }
        guard let space = draft.firstIndex(where: \.isWhitespace) else {
            let typed = draft.lowercased()
            self = .typing(ChatCommand.allCases.filter { $0.name.hasPrefix(typed) })
            return
        }
        let name = String(draft[..<space])
        if let command = ChatCommand.allCases.first(where: { $0.name == name.lowercased() }) {
            self = .command(command, argument: draft[space...].trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            self = .unknown(name)
        }
    }
}
