import Foundation

/// Runs an external command, feeding optional stdin, and returns its exit code
/// plus combined stdout+stderr. Used by the email tools (which drive `curl` for
/// SMTP/IMAP, so STARTTLS + auth + the local Proton Bridge's self-signed cert
/// are handled by curl rather than reimplemented).
enum Subprocess {
    static func run(
        _ executable: String, _ arguments: [String],
        stdin: Data? = nil, timeout: TimeInterval = 60
    ) async -> (exit: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe()
                process.standardOutput = out
                process.standardError = out
                let inPipe = Pipe()
                if stdin != nil { process.standardInput = inPipe }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                do {
                    try process.run()
                } catch {
                    killer.cancel()
                    cont.resume(returning: (-1, "spawn failed: \(error.localizedDescription)"))
                    return
                }
                if let stdin {
                    inPipe.fileHandleForWriting.write(stdin)
                    try? inPipe.fileHandleForWriting.close()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                cont.resume(returning: (process.terminationStatus,
                                        String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
