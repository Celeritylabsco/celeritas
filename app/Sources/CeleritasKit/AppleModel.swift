import Foundation
import FoundationModels

/// Apple Intelligence, already on the Mac, nothing installed and nothing sent.
///
/// Apple's session owns its tool loop: hand it tools and it calls them itself,
/// then writes the answer. That is the opposite of the HTTP path, where Agent
/// takes one turn at a time. Fighting it costs five round trips for one question,
/// measured at thirteen seconds, because every turn starts a session with no
/// memory of the last one. So the loop is left alone and the tools do the work.
///
/// A tool that changes something still cannot run on its own. Those record what
/// was asked and throw, which ends the session immediately, and the panel shows
/// the confirmation exactly as it does for any other model.
@available(macOS 26.0, *)
public struct AppleAgent: Reasoner {
    let execute: @Sendable (String, [String: String], Bool) -> ToolResult

    public init(execute: @escaping @Sendable (String, [String: String], Bool) -> ToolResult
                    = { name, args, confirm in Executor.run(name, args, confirm: confirm) }) {
        self.execute = execute
    }

    public func run(_ prompt: String, confirmDestructive: Bool = false) async throws -> Outcome {
        if let reason = AppleClient.unavailableReason { throw ClientError.transport(reason) }

        let log = RunLog()
        let session = LanguageModelSession(
            tools: AppleClient.build(into: log, execute: execute,
                                     confirmDestructive: confirmDestructive),
            instructions: Agent.systemPrompt())

        let started = Date()
        do {
            let reply = try await session.respond(to: prompt)
            let seconds = Date().timeIntervalSince(started)
            let steps = log.steps
            if steps.contains(where: { $0.tool == "intent_unclear" }) {
                return Outcome(steps: steps, reply: reply.content, stopped: "refused",
                               seconds: seconds, cost: nil, pendingConfirmation: nil)
            }
            return Outcome(steps: steps, reply: reply.content, stopped: "answered",
                           seconds: seconds, cost: nil, pendingConfirmation: nil)
        } catch {
            let seconds = Date().timeIntervalSince(started)
            if let pending = log.pending {
                return Outcome(steps: log.steps, reply: nil, stopped: "needs_confirmation",
                               seconds: seconds, cost: nil, pendingConfirmation: pending)
            }
            throw ClientError.transport(AppleClient.readable(error))
        }
    }
}

/// Availability, warm-up and schema translation. Kept apart from the loop because
/// the settings screen and onboarding ask about all three before running anything.
@available(macOS 26.0, *)
public enum AppleClient {
    /// Whether this Mac can use it, in words a person can act on.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. Try again shortly."
        case .unavailable:
            return "Apple Intelligence is not available on this Mac right now."
        }
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    /// Load the model before the first question. Cold against warm is the whole
    /// difference between a launcher that feels instant and one that does not.
    public static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: Agent.systemPrompt()).prewarm()
    }

    /// Apple's errors arrive wrapped in a tool-call failure, so the sentence worth
    /// showing is one level down. Reporting the wrapper gives nobody anything to do.
    static func readable(_ error: Error) -> String {
        if let call = error as? LanguageModelSession.ToolCallError {
            return (call.underlyingError as? LocalizedError)?.errorDescription
                ?? call.underlyingError.localizedDescription
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }


    /// One turn, for the benchmark only.
    ///
    /// The suite drives its own loop against an OpenAI-shaped endpoint and runs
    /// every tool itself against a simulated Mac, so this answers one turn at a
    /// time and hands back the tool that was picked.
    ///
    /// The history goes in as a real Transcript rather than as a paragraph of
    /// prose. Flattening it to text was measured and it is much worse: the model
    /// cannot tell that a tool already ran, so it picks the same one on every
    /// turn and burns all five. Every task came back as
    /// `set_volume -> set_volume -> set_volume -> set_volume -> set_volume` at
    /// thirteen seconds, which measures the adapter rather than the model.
    public static func askOnce(messages: [[String: Any]],
                               tools: [[String: Any]]) async throws -> Turn {
        if let reason = unavailableReason { throw ClientError.transport(reason) }

        let definitions = describe(tools)
        var entries: [Transcript.Entry] = []
        var instructions = ""
        var pendingCalls: [Transcript.ToolCall] = []
        var callIndex = 0

        for message in messages {
            let role = message["role"] as? String ?? ""
            let content = message["content"] as? String
            switch role {
            case "system":
                instructions = content ?? ""
            case "user":
                entries.append(.prompt(.init(segments: [text(content ?? "")])))
            case "assistant":
                guard let calls = message["tool_calls"] as? [[String: Any]] else { break }
                pendingCalls = calls.compactMap { call in
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else { return nil }
                    let raw = function["arguments"] as? String ?? "{}"
                    guard let arguments = try? GeneratedContent(json: raw) else { return nil }
                    callIndex += 1
                    return Transcript.ToolCall(id: "c\(callIndex)", toolName: name,
                                               arguments: arguments)
                }
                if !pendingCalls.isEmpty { entries.append(.toolCalls(.init(pendingCalls))) }
            case "tool":
                // Paired with the call before it, which is what tells the model the
                // work is done rather than still outstanding.
                let name = pendingCalls.first?.toolName ?? "tool"
                entries.append(.toolOutput(.init(id: "o\(callIndex)", toolName: name,
                                                 segments: [text(content ?? "")])))
                pendingCalls = []
            default:
                break
            }
        }
        entries.insert(.instructions(.init(segments: [text(instructions)],
                                           toolDefinitions: definitions)), at: 0)

        let log = RunLog()
        let session = LanguageModelSession(tools: recording(tools, into: log),
                                           transcript: Transcript(entries: entries))

        // A transcript ending in a tool output still needs a prompt, because the
        // API has no way to say "carry on". "Continue." on its own was measured
        // and it backfires: the system prompt says to call intent_unclear when a
        // request is ambiguous, and one bare word is ambiguous, so the model
        // refuses. This restates the rule already in the system prompt and adds
        // nothing to it.
        let follow = entries.last.map { if case .toolOutput = $0 { return true } else { return false } } ?? false
        let prompt = follow
            ? "The tool above has run. Reply in one short sentence, or call another tool if the request is not finished."
            : (lastUser(messages) ?? "Continue.")

        let started = Date()
        do {
            let reply = try await session.respond(to: prompt)
            return Turn(tool: nil, arguments: [:], text: reply.content,
                        seconds: Date().timeIntervalSince(started), cost: nil)
        } catch {
            guard let picked = log.pending else {
                throw ClientError.transport(readable(error))
            }
            return Turn(tool: picked.tool, arguments: picked.arguments, text: nil,
                        seconds: Date().timeIntervalSince(started), cost: nil)
        }
    }

    private static func text(_ value: String) -> Transcript.Segment {
        .text(.init(content: value))
    }

    /// The first turn has no history, so the question itself is the prompt and the
    /// transcript holds only the instructions.
    private static func lastUser(_ messages: [[String: Any]]) -> String? {
        for message in messages.reversed() where message["role"] as? String == "user" {
            return message["content"] as? String
        }
        return nil
    }

    private static func describe(_ tools: [[String: Any]]) -> [Transcript.ToolDefinition] {
        tools.compactMap { entry in
            guard let function = entry["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let parameters = try? schema(named: name,
                                               from: function["parameters"] as? [String: Any] ?? [:])
            else { return nil }
            return Transcript.ToolDefinition(
                name: name,
                description: function["description"] as? String ?? "",
                parameters: parameters)
        }
    }

    static func recording(_ tools: [[String: Any]],
                          into log: RunLog) -> [any FoundationModels.Tool] {
        tools.compactMap { entry -> (any FoundationModels.Tool)? in
            guard let function = entry["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let parameters = try? schema(named: name,
                                               from: function["parameters"] as? [String: Any] ?? [:])
            else { return nil }
            return LiveTool(name: name,
                            description: function["description"] as? String ?? "",
                            parameters: parameters,
                            log: log,
                            execute: { tool, args, _ in
                                // Never run anything here. Recording it as needing a
                                // person is what ends the session immediately, and
                                // the harness runs it against its simulated Mac.
                                ToolResult.confirm("recorded \(tool) \(args)")
                            },
                            confirmDestructive: false)
        }
    }

    static func build(into log: RunLog,
                      execute: @escaping @Sendable (String, [String: String], Bool) -> ToolResult,
                      confirmDestructive: Bool) -> [any FoundationModels.Tool] {
        ToolCatalog.schema().compactMap { entry -> (any FoundationModels.Tool)? in
            guard let function = entry["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let parameters = try? schema(named: name,
                                               from: function["parameters"] as? [String: Any] ?? [:])
            else { return nil }
            return LiveTool(name: name,
                            description: function["description"] as? String ?? "",
                            parameters: parameters,
                            log: log,
                            execute: execute,
                            confirmDestructive: confirmDestructive)
        }
    }

    /// Turn one tool's JSON Schema into the runtime schema Apple's API wants.
    ///
    /// The catalogue is read from a file at startup, so there is no compile-time
    /// type to hang @Generable on and the dynamic route is the only one available.
    static func schema(named name: String,
                       from parameters: [String: Any]) throws -> GenerationSchema {
        let properties = parameters["properties"] as? [String: Any] ?? [:]
        let required = Set(parameters["required"] as? [String] ?? [])
        // Sorted, so one tool produces one schema on every launch.
        let fields = properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
            let spec = properties[key] as? [String: Any] ?? [:]
            let type: DynamicGenerationSchema
            if let choices = spec["enum"] as? [String], !choices.isEmpty {
                type = DynamicGenerationSchema(name: "\(name).\(key)", anyOf: choices)
            } else {
                switch spec["type"] as? String {
                case "integer": type = DynamicGenerationSchema(type: Int.self)
                case "number": type = DynamicGenerationSchema(type: Double.self)
                case "boolean": type = DynamicGenerationSchema(type: Bool.self)
                default: type = DynamicGenerationSchema(type: String.self)
                }
            }
            return .init(name: key,
                         description: spec["description"] as? String,
                         schema: type,
                         isOptional: !required.contains(key))
        }
        let root = DynamicGenerationSchema(name: name, properties: fields)
        return try GenerationSchema(root: root, dependencies: [])
    }
}

/// What happened inside the session, written from the tools and read after it
/// ends. A lock rather than an actor, because Tool.call cannot await this and the
/// critical section is one append.
final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Step] = []
    private var waiting: Step?

    var steps: [Step] { lock.lock(); defer { lock.unlock() }; return recorded }
    var pending: Step? { lock.lock(); defer { lock.unlock() }; return waiting }

    func append(_ step: Step) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(step)
    }

    /// First one wins. The session ends on the first of these anyway, and saying
    /// so here means it does not depend on that.
    func hold(_ step: Step) {
        lock.lock(); defer { lock.unlock() }
        if waiting == nil { waiting = step }
    }
}

/// Raised to end the session the moment something needs a person. Never displayed.
struct NeedsPerson: Error {}

@available(macOS 26.0, *)
struct LiveTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let log: RunLog
    let execute: @Sendable (String, [String: String], Bool) -> ToolResult
    let confirmDestructive: Bool

    func call(arguments: GeneratedContent) async throws -> String {
        var flat: [String: String] = [:]
        if let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.jsonString.utf8))
            as? [String: Any] {
            for (key, value) in parsed { flat[key] = String(describing: value) }
        }
        let result = execute(name, flat, confirmDestructive)
        let step = Step(tool: name, arguments: flat, result: result)
        if result.needsConfirmation {
            log.hold(step)
            throw NeedsPerson()
        }
        log.append(step)
        return result.output
    }
}
