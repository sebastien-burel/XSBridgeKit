import Foundation

/// Cached bundle of the JS-authored HTTP / pure tools (`current_datetime`,
/// `fetch_url`, `web_search`). Each backs an XS engine, so — like `JSProviders`
/// — instances are cached by config: a caller that rebuilds the tool list on
/// every SwiftUI render reuses the same engine instead of spinning up a new one.
public enum JSTools {
    private static let lock = NSLock()
    private static var cache: [String: JSToolBundle] = [:]

    /// The JS HTTP/pure tools, ready to add to a `ToolRegistry`. `web_search` is
    /// included only when a Brave key is supplied (it needs one). Cached by key.
    public static func bundle(braveAPIKey: String, memory: MemoryStoring) -> JSToolBundle? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[braveAPIKey] { return existing }

        var names = ["datetime", "fetch-url"]
        var config: [String: Any] = [:]
        if !braveAPIKey.isEmpty {
            names.append("web-search")
            config["braveApiKey"] = braveAPIKey
        }
        guard let bundle = JSToolBundle(
            toolModules: names, config: config,
            tools: ToolRegistry(tools: []), memory: memory)
        else { return nil }
        cache[braveAPIKey] = bundle
        return bundle
    }
}
