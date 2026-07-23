import Foundation

/// Models list response (used only for the Settings model picker; the chat
/// flow itself goes through JSONSerialization for both request and stream
/// parsing because Gemini's parts can mix text and functionCall objects).
public struct GoogleModelsResponse: Decodable {
    public struct Model: Decodable, Identifiable, Hashable {
        public let name: String                            // "models/gemini-2.5-flash"
        public let displayName: String?
        public let supportedGenerationMethods: [String]?

        public var id: String {
            name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
    }
    public let models: [Model]
}
