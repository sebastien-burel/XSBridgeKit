import Foundation

/// A folder the user has explicitly authorised the app to read. Persistence
/// stores a security-scoped bookmark (the sandbox requires this to regain
/// access across launches); the display name is the folder's last path
/// component, kept so the UI and tools can show something readable.
public struct FileSpace: Identifiable, Hashable, Codable {
    public let id: UUID
    public let name: String
    public var bookmark: Data
    /// Whether this folder may also serve as a module root — i.e. an agent may
    /// `import` code from it. Off by default: authorising a folder for the file
    /// tools grants read access, not code execution, so importability is an
    /// explicit opt-in (read → execute is an escalation).
    public var importable: Bool
    /// Whether this (importable) space is also the default module root — the
    /// one bare specifiers resolve against, so agents can `import "module"`
    /// with no prefix. At most one space is default (enforced by the store).
    public var isDefaultRoot: Bool

    public init(
        id: UUID = UUID(), name: String, bookmark: Data,
        importable: Bool = false, isDefaultRoot: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.importable = importable
        self.isDefaultRoot = isDefaultRoot
    }

    // Back-compat: spaces persisted before these flags existed decode to false
    // (rather than failing the whole list's decode and dropping every space).
    private enum CodingKeys: String, CodingKey { case id, name, bookmark, importable, isDefaultRoot }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bookmark = try c.decode(Data.self, forKey: .bookmark)
        importable = try c.decodeIfPresent(Bool.self, forKey: .importable) ?? false
        isDefaultRoot = try c.decodeIfPresent(Bool.self, forKey: .isDefaultRoot) ?? false
    }
}

/// A resolved, security-scoped root ready to hand to the file tools. The URL
/// carries the sandbox capability; callers must bracket actual file access
/// with `start`/`stopAccessingSecurityScopedResource`.
public struct AuthorizedRoot: Hashable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}
