import Foundation

/// Handles secret placeholders in plugin manifests. A manifest never stores a
/// secret directly: it writes a marker like `***APIKEY***` in a header value
/// or URL, and the actual value lives in the Keychain. At request time the
/// markers are substituted in.
public enum PluginSecrets {
    /// Matches `***NAME***` where NAME is letters, digits or underscores.
    private static let pattern = try! NSRegularExpression(pattern: "\\*\\*\\*([A-Za-z0-9_]+)\\*\\*\\*")

    /// The distinct placeholder names found in `text`.
    public static func placeholders(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        var names: Set<String> = []
        pattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: text) else { return }
            names.insert(String(text[r]))
        }
        return names
    }

    /// Replaces every `***NAME***` for which `secrets[NAME]` exists. Unknown
    /// markers are left untouched (so a missing secret surfaces as an auth
    /// failure rather than a silent empty value).
    public static func substitute(in text: String, secrets: [String: String]) -> String {
        var result = text
        for (name, value) in secrets {
            result = result.replacingOccurrences(of: "***\(name)***", with: value)
        }
        return result
    }
}

/// Argument placeholders (`{name}`) let a manifest put tool arguments into the
/// URL path or query, e.g. `https://api/{symbol}`. Distinct from secrets: the
/// values come from the model's call, not the Keychain.
enum PluginArguments {
    private static let pattern = try! NSRegularExpression(pattern: "\\{([A-Za-z0-9_]+)\\}")

    /// Substitutes `{name}` with the percent-encoded argument value. Returns
    /// the filled string and the set of argument names that were consumed (so
    /// the caller can avoid also appending them as query items).
    static func substitute(
        in template: String,
        arguments: [String: Any]
    ) -> (result: String, usedKeys: Set<String>) {
        let range = NSRange(template.startIndex..., in: template)
        var used: Set<String> = []
        var result = template
        let matches = pattern.matches(in: template, range: range).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let name = String(result[nameRange])
            guard let value = arguments[name] else { continue }
            let encoded = stringify(value)
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            result.replaceSubrange(whole, with: encoded)
            used.insert(name)
        }
        return (result, used)
    }

    /// Same NSNumber/Bool bridging trap as in HTTPPluginTool — keep them in
    /// sync so `count: 1` doesn't render as `"true"` in the URL path.
    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }
}
