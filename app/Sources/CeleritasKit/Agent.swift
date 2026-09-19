import Foundation

public struct Step: Sendable {
    public let tool: String
    public let arguments: [String: String]
    public let result: ToolResult
}

public struct Outcome: Sendable {
    public let steps: [Step]
    public let reply: String?
    public let stopped: String
    public let seconds: Double
    public let cost: Double?
    public let pendingConfirmation: Step?
}

/// The loop. The model takes a turn, we run what it chose, we hand back the
/// result, it takes another. It stops when it answers in prose, refuses, hits a
/// destructive tool, or runs out of turns.
public struct Agent: Sendable {
    public static let maxTurns = 5

    let client: any ModelClient
    let execute: @Sendable (String, [String: String], Bool) -> ToolResult

    public init(client: any ModelClient,
                execute: @escaping @Sendable (String, [String: String], Bool) -> ToolResult
                    = { name, args, confirm in Executor.run(name, args, confirm: confirm) }) {
        self.client = client
        self.execute = execute
    }

    /// The date is in the prompt on every request. A model should never spend a
    /// turn asking what day it is.
    static func systemPrompt(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy"
        let t = DateFormatter()
        t.locale = Locale(identifier: "en_US_POSIX")
        t.dateFormat = "HH:mm"
        return """
        You control a Mac with a fixed set of tools. Choose one tool at a time.

        Today is \(f.string(from: now)). The time is \(t.string(from: now)).

        Rules:
        - Call intent_unclear, never plain text, when the request is ambiguous, off
          topic, incomplete, or asks for something the tools cannot do.
        - After a tool returns, either call another tool or reply in one short sentence.
        - Never call the same tool twice with the same arguments.
        """
    }

    public func run(_ prompt: String, confirmDestructive: Bool = false) async throws -> Outcome {
        var messages: [[String: Any]] = [
            ["role": "system", "content": Agent.systemPrompt()],
            ["role": "user", "content": prompt],
        ]
        let tools = ToolCatalog.schema()
        var steps: [Step] = []
        var seconds = 0.0
        var cost: Double? = nil

        for turn in 0..<Agent.maxTurns {
            let reply = try await client.ask(messages: messages, tools: tools)
            seconds += reply.seconds
            if let c = reply.cost { cost = (cost ?? 0) + c }

            guard let tool = reply.tool else {
                return Outcome(steps: steps, reply: reply.text, stopped: "answered",
                               seconds: seconds, cost: cost, pendingConfirmation: nil)
            }

            let result = execute(tool, reply.arguments, confirmDestructive)
            let step = Step(tool: tool, arguments: reply.arguments, result: result)

            // A destructive tool stops the loop and hands the decision to the person.
            if result.needsConfirmation {
                return Outcome(steps: steps, reply: nil, stopped: "needs_confirmation",
                               seconds: seconds, cost: cost, pendingConfirmation: step)
            }
            steps.append(step)

            if tool == "intent_unclear" {
                return Outcome(steps: steps, reply: result.output, stopped: "refused",
                               seconds: seconds, cost: cost, pendingConfirmation: nil)
            }

            messages.append([
                "role": "assistant", "content": NSNull(),
                "tool_calls": [[
                    "id": "c\(turn)", "type": "function",
                    "function": ["name": tool,
                                 "arguments": (try? String(data: JSONSerialization.data(
                                    withJSONObject: reply.arguments), encoding: .utf8)) ?? "{}"],
                ]],
            ])
            messages.append([
                "role": "tool", "tool_call_id": "c\(turn)",
                "content": String(result.output.prefix(1500)),
            ])
        }

        return Outcome(steps: steps, reply: nil, stopped: "max_turns",
                       seconds: seconds, cost: cost, pendingConfirmation: nil)
    }
}
