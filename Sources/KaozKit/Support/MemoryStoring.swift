import Foundation

/// Abstraction over the durable "pinned preferences" memory store. The agent
/// runtime and the memory tools depend on this protocol rather than on the
/// app's concrete `@MainActor MemoryStore`, so a headless consumer (kaoz)
/// can supply a plain file-backed implementation. The app conforms its own
/// `MemoryStore` to it.
@MainActor
public protocol MemoryStoring: AnyObject, Sendable {
    var memories: [Memory] { get }
    @discardableResult
    func add(title: String, content: String) -> Memory
    func delete(id: UUID)
    func memory(id: UUID) -> Memory?
}
