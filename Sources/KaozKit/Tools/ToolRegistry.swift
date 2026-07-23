import Foundation

/// Holds the tools currently exposed to the LLM. The registry is the only
/// place that knows how to map a tool name (as received from the model) back
/// to the concrete implementation. ChatSession asks the registry to execute
/// each ToolCall and gets a ToolResult back, never throws — failures travel
/// inside the result so we can show them to the LLM as feedback.
public struct ToolRegistry: Sendable {
    private let toolsByName: [String: any Tool]

    public init(tools: [any Tool]) {
        var map: [String: any Tool] = [:]
        for tool in tools {
            map[tool.spec.name] = tool
        }
        self.toolsByName = map
    }

    public var all: [any Tool] { Array(toolsByName.values) }

    public var specs: [ToolSpec] { all.map(\.spec) }

    public func tool(named name: String) -> (any Tool)? {
        toolsByName[name]
    }

    /// Executes a call and turns any thrown error into a non-fatal
    /// ToolResult with isError=true. The LLM sees the error message as the
    /// tool output, which usually lets it recover (retry, correct args, give
    /// up gracefully).
    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let tool = toolsByName[call.toolName] else {
            return ToolResult(
                callID: call.id,
                content: "Unknown tool: \(call.toolName)",
                isError: true
            )
        }
        do {
            let content = try await tool.execute(arguments: call.arguments)
            return ToolResult(callID: call.id, content: content, isError: false)
        } catch let error as ToolError {
            return ToolResult(
                callID: call.id,
                content: error.errorDescription ?? "Tool error.",
                isError: true
            )
        } catch {
            return ToolResult(
                callID: call.id,
                content: error.localizedDescription,
                isError: true
            )
        }
    }
}
