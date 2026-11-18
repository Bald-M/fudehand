import Foundation

/// A saved chat conversation: the transcript's entries, with the name and time shown in the history menu.
public struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let entries: [ChatEntry]

    public init(id: UUID, transcript: ChatTranscript, updatedAt: Date) {
        self.id = id
        title = transcript.title
        self.updatedAt = updatedAt
        entries = transcript.entries
    }
}

/// The chat conversations kept on this Mac: one JSON file per conversation in `directory`, keeping the `limit` newest.
public struct ChatHistory: Sendable {
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

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func read(_ file: URL) -> ChatConversation? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ChatConversation.self, from: $0) }
    }
}
