import Foundation

/// A durable note the assistant chose to remember about the user or an ongoing
/// task. Memories persist across conversations and are injected into the
/// system prompt of future chats so the model stays consistent without having
/// to re-ask.
public struct Memory: Identifiable, Hashable, Codable {
    public let id: UUID
    public var title: String
    public var content: String
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, content: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
    }
}
