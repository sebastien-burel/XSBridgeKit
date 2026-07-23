import Foundation
import KaozJSCore

/// Swift side of the native `__http` primitive (installed by KaozHostC). It
/// performs the request off the XS thread, streams each response chunk back
/// through the reverse channel (`xsServiceEmit` → the JS `onChunk`), and
/// settles with `{status, headers}` via `xsServiceResolve`. Stateless: the
/// request is fully described by the JSON, so no bridge context is needed.
enum HttpHost {

    /// One shared session; providers stream SSE, so no response caching.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    static func send(bridge: UnsafeMutableRawPointer, id: UInt32, requestJSON: String) {
        guard
            let data = requestJSON.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let urlString = obj["url"] as? String,
            let url = URL(string: urlString)
        else {
            complete(bridge, id, ok: false, jsonValue: "invalid http request")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = (obj["method"] as? String)?.uppercased() ?? "GET"
        if let headers = obj["headers"] as? [String: String] {
            for (key, value) in headers {
                // Sanitize the value: trim surrounding whitespace (HTTP OWS, and
                // a common paste artefact) and drop any embedded CR/LF — a stray
                // newline in a pasted API key otherwise makes URLSession silently
                // drop the whole header (e.g. Brave's X-Subscription-Token → 422).
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                request.setValue(clean, forHTTPHeaderField: key)
            }
        }
        if let body = obj["body"] as? String, !body.isEmpty {
            request.httpBody = Data(body.utf8)
        }

        Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                // Stream the body line by line (SSE is line-oriented; a plain
                // JSON body simply arrives as one or a few lines). Re-add the
                // stripped newline so the JS side can reassemble verbatim.
                for try await line in bytes.lines {
                    emit(bridge, id, chunk: line + "\n")
                }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                var headers: [String: String] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] {
                    if let k = key as? String, let v = value as? String { headers[k] = v }
                }
                complete(bridge, id, ok: true,
                         jsonObject: ["status": status, "headers": headers])
            } catch {
                complete(bridge, id, ok: false, jsonValue: error.localizedDescription)
            }
        }
    }

    // MARK: - Settling helpers

    private static func emit(_ bridge: UnsafeMutableRawPointer, _ id: UInt32, chunk: String) {
        jsonString(chunk).withCString { xsServiceEmit(bridge, id, $0) }
    }

    private static func complete(_ bridge: UnsafeMutableRawPointer, _ id: UInt32,
                                 ok: Bool, jsonObject: [String: Any]) {
        (jsonEncode(jsonObject) ?? "{}").withCString {
            ok ? xsServiceResolve(bridge, id, $0) : xsServiceReject(bridge, id, $0)
        }
    }

    private static func complete(_ bridge: UnsafeMutableRawPointer, _ id: UInt32,
                                 ok: Bool, jsonValue: String) {
        jsonString(jsonValue).withCString {
            ok ? xsServiceResolve(bridge, id, $0) : xsServiceReject(bridge, id, $0)
        }
    }

    /// JSON-encode a String as a JSON string literal (the JS side JSON.parses it).
    private static func jsonString(_ value: String) -> String {
        (try? String(data: JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)) ?? "\"\""
    }

    private static func jsonEncode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }
}

@_cdecl("xsbHttpSend")
func xsbHttpSend(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32,
                _ requestJSON: UnsafePointer<CChar>?) {
    guard let bridge, let cstr = requestJSON else { return }
    HttpHost.send(bridge: bridge, id: id, requestJSON: String(cString: cstr))
}
