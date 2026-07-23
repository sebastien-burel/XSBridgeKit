import Foundation

/// Mailbox access over IMAP/SMTP. Defaults target **Proton Bridge** (a local
/// server exposing a Proton account as standard IMAP/SMTP with STARTTLS + a
/// self-signed cert + a bridge-specific password). The tools drive `curl`, so
/// STARTTLS, auth and the self-signed cert are handled by curl.
public struct EmailConfig: Sendable {
    /// How TLS is negotiated. Recent Proton Bridge uses **implicit TLS** (SSL —
    /// a `smtps://`/`imaps://` handshake on connect), NOT STARTTLS.
    public enum TLSMode: String, Sendable { case ssl, starttls, none }

    public let host: String
    public let smtpPort: Int
    public let imapPort: Int
    public let username: String
    public let password: String
    public let fromAddress: String
    /// Proton Bridge uses DIFFERENT TLS per protocol: SMTP = implicit (ssl),
    /// IMAP = STARTTLS. Hence separate modes.
    public let smtpTLS: TLSMode
    public let imapTLS: TLSMode

    public init(
        host: String = "127.0.0.1", smtpPort: Int = 1025, imapPort: Int = 1143,
        username: String, password: String, fromAddress: String,
        smtpTLS: TLSMode = .ssl, imapTLS: TLSMode = .starttls
    ) {
        self.host = host
        self.smtpPort = smtpPort
        self.imapPort = imapPort
        self.username = username
        self.password = password
        self.fromAddress = fromAddress
        self.smtpTLS = smtpTLS
        self.imapTLS = imapTLS
    }

    /// URL scheme per mode: implicit TLS uses smtps/imaps; STARTTLS/none use the
    /// plain scheme (STARTTLS then adds --ssl-reqd via `flags`).
    var smtpURL: String { "\(smtpTLS == .ssl ? "smtps" : "smtp")://\(host):\(smtpPort)" }
    func imapURL(_ path: String) -> String { "\(imapTLS == .ssl ? "imaps" : "imap")://\(host):\(imapPort)\(path)" }

    /// curl flags for a protocol: credentials + TLS (accepting the self-signed cert).
    func flags(_ mode: TLSMode) -> [String] {
        var a = password.isEmpty ? [] : ["--user", "\(username):\(password)"]
        switch mode {
        case .ssl: a += ["--insecure"]                    // implicit TLS via smtps/imaps
        case .starttls: a += ["--ssl-reqd", "--insecure"]
        case .none: break
        }
        return a
    }
}

private let curlPath = "/usr/bin/curl"

/// Sends an email through SMTP (Proton Bridge by default).
public struct SendEmailTool: Tool {
    public let config: EmailConfig
    public init(config: EmailConfig) { self.config = config }

    public let spec = ToolSpec(
        name: "send_email",
        description: """
        Sends a plain-text email from the user's mailbox. `to` may be a comma-
        separated list. Returns confirmation or the server error.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "to": { "type": "string", "description": "Recipient address(es), comma-separated." },
            "subject": { "type": "string" },
            "body": { "type": "string", "description": "Plain-text message body." }
          },
          "required": ["to", "subject", "body"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable { let to: String; let subject: String; let body: String }

    public func execute(arguments: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else {
            throw ToolError.invalidArguments(reason: "expected {to, subject, body}")
        }
        let recipients = args.to.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard !recipients.isEmpty else {
            throw ToolError.invalidArguments(reason: "no recipient in `to`")
        }
        let message = Self.rfc822(
            from: config.fromAddress, to: args.to, subject: args.subject, body: args.body)
        var curlArgs = [
            "--silent", "--show-error",
            "--url", config.smtpURL,
            "--mail-from", config.fromAddress,
        ]
        for r in recipients { curlArgs += ["--mail-rcpt", r] }
        curlArgs += ["--upload-file", "-"]
        curlArgs += config.flags(config.smtpTLS)

        let (exit, output) = await Subprocess.run(
            curlPath, curlArgs, stdin: Data(message.utf8), timeout: 60)
        guard exit == 0 else {
            throw ToolError.execution(message: "send_email failed (curl \(exit)): \(output.prefix(500))")
        }
        return "email sent to \(args.to)"
    }

    private static func rfc822(from: String, to: String, subject: String, body: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return [
            "From: \(from)",
            "To: \(to)",
            "Subject: \(subject)",
            "Date: \(df.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "",
            body,
        ].joined(separator: "\r\n") + "\r\n"
    }
}

/// Reads the most recent messages from INBOX over IMAP (Proton Bridge default),
/// returning best-effort parsed { from, subject, date, snippet } per message.
public struct ReadEmailTool: Tool {
    public let config: EmailConfig
    public init(config: EmailConfig) { self.config = config }

    public let spec = ToolSpec(
        name: "read_email",
        description: """
        Reads the most recent messages from the INBOX (default 5, max 20),
        newest first, returning { from, subject, date, snippet } for each.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "limit": { "type": "integer", "description": "How many recent messages (default 5).", "minimum": 1, "maximum": 20 }
          },
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable { let limit: Int? }

    public func execute(arguments: Data) async throws -> String {
        let limit = min((try? JSONDecoder().decode(Args.self, from: arguments))?.limit ?? 5, 20)

        // Message count via STATUS.
        let (se, statusOut) = await Subprocess.run(
            curlPath, ["--silent", "--url", config.imapURL("/INBOX"),
                       "--request", "STATUS INBOX (MESSAGES)"] + config.flags(config.imapTLS))
        guard se == 0 else {
            throw ToolError.execution(message: "read_email (status) failed (curl \(se)): \(statusOut.prefix(300))")
        }
        guard let count = Self.parseCount(statusOut), count > 0 else { return "[]" }

        // Fetch the last `limit` messages by sequence number, newest first.
        var results: [[String: Any]] = []
        let start = max(1, count - limit + 1)
        for seq in stride(from: count, through: start, by: -1) {
            let (fe, raw) = await Subprocess.run(
                curlPath, ["--silent", "--url", config.imapURL("/INBOX;MAILINDEX=\(seq)")] + config.flags(config.imapTLS))
            if fe == 0, !raw.isEmpty { results.append(Self.parseMessage(raw)) }
        }
        let json = (try? JSONSerialization.data(withJSONObject: results))
            .flatMap { String(data: $0, encoding: .utf8) }
        return json ?? "[]"
    }

    /// `* STATUS INBOX (MESSAGES 42)` → 42.
    private static func parseCount(_ s: String) -> Int? {
        guard let r = s.range(of: "MESSAGES ") else { return nil }
        let tail = s[r.upperBound...].prefix { $0.isNumber }
        return Int(tail)
    }

    /// Extract From/Subject/Date headers and a short body snippet from a raw
    /// RFC822 message (best-effort — the agent gets structured fields to act on).
    private static func parseMessage(_ raw: String) -> [String: Any] {
        var headers: [String: String] = [:]
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerBlock = parts.first ?? raw
        for line in headerBlock.components(separatedBy: "\r\n") where line.contains(":") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                if ["from", "subject", "date"].contains(key), headers[key] == nil {
                    headers[key] = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let body = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""
        return [
            "from": headers["from"] ?? "",
            "subject": headers["subject"] ?? "",
            "date": headers["date"] ?? "",
            "snippet": String(cleanSnippet(body).prefix(300)),
        ]
    }

    /// Make a readable snippet: decode quoted-printable, strip HTML tags, and
    /// collapse whitespace (email bodies are usually QP-encoded and often HTML).
    private static func cleanSnippet(_ raw: String) -> String {
        var s = decodeQuotedPrintable(raw)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode quoted-printable to UTF-8 (=XX byte escapes, =\r\n soft breaks).
    private static func decodeQuotedPrintable(_ s: String) -> String {
        let arr = Array(s.utf8)
        var bytes: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> Int? {
            switch b {
            case 0x30...0x39: return Int(b - 0x30)
            case 0x41...0x46: return Int(b - 0x41 + 10)
            case 0x61...0x66: return Int(b - 0x61 + 10)
            default: return nil
            }
        }
        while i < arr.count {
            if arr[i] == UInt8(ascii: "="), i + 2 < arr.count {
                if arr[i + 1] == 0x0D, arr[i + 2] == 0x0A { i += 3; continue }   // soft line break
                if let hi = hex(arr[i + 1]), let lo = hex(arr[i + 2]) {
                    bytes.append(UInt8(hi * 16 + lo)); i += 3; continue
                }
            }
            bytes.append(arr[i]); i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
