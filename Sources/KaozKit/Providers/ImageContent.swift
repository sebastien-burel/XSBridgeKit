import Foundation

/// Reads image attachments (local file URLs carried on a `ChatMessage`)
/// and encodes them for the various provider wire formats. Shared by the
/// cloud clients so each builds multimodal requests the same way.
public enum ImageContent {
    /// Base64 payload + MIME type for one attachment, or `nil` if the file
    /// can't be read.
    public static func encode(_ url: URL) -> (mime: String, base64: String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (mimeType(for: url), data.base64EncodedString())
    }

    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/jpeg"
        }
    }

    /// OpenAI-style content part: `{"type":"image_url","image_url":{"url":"data:…"}}`.
    public static func openAIParts(for urls: [URL]) -> [[String: Any]] {
        urls.compactMap { url in
            guard let (mime, b64) = encode(url) else { return nil }
            return [
                "type": "image_url",
                "image_url": ["url": "data:\(mime);base64,\(b64)"],
            ]
        }
    }

    /// Anthropic content block: `{"type":"image","source":{"type":"base64",…}}`.
    public static func anthropicBlocks(for urls: [URL]) -> [[String: Any]] {
        urls.compactMap { url in
            guard let (mime, b64) = encode(url) else { return nil }
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": mime, "data": b64],
            ]
        }
    }

    /// Gemini part: `{"inlineData":{"mimeType":…,"data":…}}`.
    public static func geminiParts(for urls: [URL]) -> [[String: Any]] {
        urls.compactMap { url in
            guard let (mime, b64) = encode(url) else { return nil }
            return ["inlineData": ["mimeType": mime, "data": b64]]
        }
    }
}
