import Foundation
import Network

/// A tiny HTTP server: the universal **inbound channel**. Each request's body is
/// handed to `handler` (which delivers it to the resident agent); the handler's
/// result becomes the HTTP response body. Any external system that can POST —
/// a Slack/Telegram/GitHub webhook, a cron curl, an IFTTT applet — can wake and
/// query the agent. Foundation + Network.framework only, no dependency.
///
/// Minimal on purpose: parses the request line + headers + a Content-Length body
/// (enough for webhooks); no chunked transfer, no keep-alive (one request per
/// connection). Bind to loopback in front of a real proxy for anything public.
public final class WebhookServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tykaoz.webhook")
    private let handler: @Sendable (Data) async -> Data

    /// `handler` receives the raw request body and returns the response body.
    public init(port: UInt16, handler: @escaping @Sendable (Data) async -> Data) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ToolError.invalidArguments(reason: "invalid webhook port \(port)")
        }
        self.listener = try NWListener(using: .tcp, on: nwPort)
        self.handler = handler
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let body = Self.parseBody(buf) {
                Task {
                    let response = await self.handler(body)
                    self.respond(conn, body: response)
                }
            } else if isComplete || error != nil {
                self.respond(conn, body: Data(#"{"error":"bad request"}"#.utf8), status: "400 Bad Request")
            } else {
                self.receive(conn, buffer: buf)   // headers/body not complete yet
            }
        }
    }

    /// The request body once the full request (headers + Content-Length bytes) is
    /// present in `data`, else nil (need more).
    private static func parseBody(_ data: Data) -> Data? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) ?? ""
        var contentLength = 0
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("content-length") == .orderedSame {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = sep.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        return Data(data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)])
    }

    private func respond(_ conn: NWConnection, body: Data, status: String = "200 OK") {
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
}
