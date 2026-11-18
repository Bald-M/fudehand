import CryptoKit
import Foundation

/// A saved chat conversation: the transcript's entries, with the name and time shown in the history menu.
public struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let entries: [ChatEntry]
    /// The model provider and model the conversation uses; nil in conversations saved before these were recorded.
    /// The API key and the base URL are never saved here.
    public let provider: String?
    public let model: String?

    public init(id: UUID, transcript: ChatTranscript, updatedAt: Date, provider: String? = nil, model: String? = nil) {
        self.id = id
        title = transcript.title
        self.updatedAt = updatedAt
        entries = transcript.entries
        self.provider = provider
        self.model = model
    }
}

/// The chat conversations kept on this Mac for one design document: one JSON file per conversation in `directory`, keeping the
/// `limit` newest, and the list of the ones open as tabs.
public struct ChatHistory: Sendable {
    /// The conversations open as tabs, in tab order, and the selected one.
    public struct OpenTabs: Codable, Equatable, Sendable {
        public let ids: [UUID]
        public let selected: UUID?

        public init(ids: [UUID], selected: UUID?) {
            self.ids = ids
            self.selected = selected
        }
    }

    public struct Summary: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let updatedAt: Date
    }

    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 50) {
        self.directory = directory
        self.limit = limit
    }

    /// The conversations of the project file at `path`, under `root`. The directory is named by a hash of the path, so a file that
    /// is moved or renamed starts without conversations.
    public static func document(path: String, root: URL, limit: Int = 50) -> ChatHistory {
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return ChatHistory(directory: root.appendingPathComponent("documents").appendingPathComponent(name), limit: limit)
    }

    /// The conversations of the design document that has no project file yet.
    public static func unsaved(root: URL) -> ChatHistory {
        ChatHistory(directory: root.appendingPathComponent("unsaved"))
    }

    /// The saved conversations, newest first; files that cannot be read are skipped.
    public func list() -> [Summary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(read)
            .map { Summary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: UUID) -> ChatConversation? { read(file(id)) }

    public func save(_ conversation: ChatConversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(conversation).write(to: file(conversation.id), options: .atomic)
        for old in list().dropFirst(limit) { delete(old.id) }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Nil when no tab list was saved or it cannot be read.
    public func openTabs() -> OpenTabs? {
        (try? Data(contentsOf: tabsFile)).flatMap { try? JSONDecoder().decode(OpenTabs.self, from: $0) }
    }

    public func saveOpenTabs(_ tabs: OpenTabs) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(tabs).write(to: tabsFile, options: .atomic)
    }

    /// Copies the files of `other` that this directory does not have, for a document saved to a new file.
    public func adopt(_ other: ChatHistory) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: other.directory, includingPropertiesForKeys: nil) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files { try? FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent)) }
    }

    /// Deletes every conversation and the tab list.
    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var tabsFile: URL { directory.appendingPathComponent("tabs.json") }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func read(_ file: URL) -> ChatConversation? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ChatConversation.self, from: $0) }
    }
}
