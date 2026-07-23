import Foundation

/// JSON marshalling helpers for the XS bridge. The C layer hands Swift the
/// `JSON.stringify` of a call's params array, and expects JSON strings back
/// (it `JSON.parse`s them before settling the JS promise). Everything that
/// crosses the bridge is UTF-8 JSON — never an `xsSlot` — so these helpers are
/// the only place values are encoded/decoded.
public nonisolated enum AgentJSON {

    /// Serialise a JSON-compatible value (String, NSNumber, Bool, NSNull,
    /// arrays, dictionaries) to a JSON string. Falls back to `null`.
    public static func string(_ value: Any?) -> String {
        let object = value ?? NSNull()
        guard JSONSerialization.isValidJSONObject(object) || isFragment(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8)
        else { return "null" }
        return json
    }

    /// Parse a JSON array string (a call's params) into `[Any]`. Empty on failure.
    public static func params(_ json: String) -> [Any] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) as? [Any]
        else { return [] }
        return array
    }

    /// Decode the `messages` argument of `host.llm.chat` — an array of
    /// `{ role, content }` objects — into `[ChatMessage]`. Unknown roles map
    /// to `.user`.
    public static func decodeMessages(_ value: Any?) -> [ChatMessage] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.map { entry in
            let roleString = (entry["role"] as? String) ?? "user"
            let content = (entry["content"] as? String) ?? ""
            let role: ChatMessage.Role
            switch roleString {
            case "system":    role = .system
            case "assistant": role = .assistant
            case "tool":      role = .toolResult
            default:          role = .user
            }
            return ChatMessage(role: role, content: content)
        }
    }

    /// A JS tool's result reaches us as `JSON.stringify(value)`. If that value
    /// was a plain string, return it unquoted (clean tool text); otherwise keep
    /// the JSON text so structured results round-trip.
    public static func unwrapResult(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]),
           let text = object as? String {
            return text
        }
        return raw
    }

    /// Embed an arbitrary Swift string as a JS string literal for `eval`.
    /// A JSON string is a valid JS string literal, so we reuse `string(_:)`.
    public static func jsLiteral(_ value: String) -> String { string(value) }

    private static func isFragment(_ object: Any) -> Bool {
        object is String || object is NSNumber || object is Bool || object is NSNull
    }
}
