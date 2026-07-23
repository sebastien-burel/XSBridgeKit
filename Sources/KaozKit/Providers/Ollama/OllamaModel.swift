import Foundation

public struct OllamaModel: Decodable, Identifiable, Hashable {
    public let name: String
    public let size: Int64
    public let modifiedAt: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case modifiedAt = "modified_at"
    }
}

public struct OllamaTagsResponse: Decodable {
    public let models: [OllamaModel]
}
