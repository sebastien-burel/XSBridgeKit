import Foundation

/// Runs a shell command via `/bin/sh -c` in a fixed working directory and
/// returns its combined stdout+stderr and exit code. **Powerful and opt-in**:
/// the consumer only registers this tool when the user explicitly grants shell
/// access, and pins the working directory. There is no command allowlist — the
/// opt-in itself is the trust boundary — so grant it only for agents/dirs you
/// trust (mirrors a coding assistant's shell tool).
public struct ShellTool: Tool {
    public let workingDirectory: URL
    public let timeout: TimeInterval

    public init(workingDirectory: URL, timeout: TimeInterval = 60) {
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public let spec = ToolSpec(
        name: "run_shell",
        description: """
        Runs a shell command (/bin/sh -c) in the agent's working directory and
        returns { exit, output } where output is the combined stdout+stderr.
        Times out after a bounded delay. Use for local automation the user has
        authorised.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "command": { "type": "string", "description": "The shell command to run." }
          },
          "required": ["command"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable { let command: String }

    public func execute(arguments: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else {
            throw ToolError.invalidArguments(reason: "expected {command: string}")
        }
        let cwd = workingDirectory
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", args.command]
                process.currentDirectoryURL = cwd
                let pipe = Pipe()                 // merged stdout+stderr — single reader, no deadlock
                process.standardOutput = pipe
                process.standardError = pipe
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                do {
                    try process.run()
                } catch {
                    killer.cancel()
                    cont.resume(throwing: ToolError.execution(
                        message: "run_shell failed to start: \(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let output = String(data: data, encoding: .utf8) ?? ""
                let result: [String: Any] = [
                    "exit": Int(process.terminationStatus), "output": output,
                ]
                let json = (try? JSONSerialization.data(withJSONObject: result))
                    .flatMap { String(data: $0, encoding: .utf8) }
                cont.resume(returning: json ?? output)
            }
        }
    }
}
