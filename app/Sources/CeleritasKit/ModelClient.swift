import Foundation

/// One question, one answer, whoever is answering.
///
/// Agent drives an OpenAI-shaped loop over HTTP. Apple's session drives its own
/// loop in process and cannot be made to hand control back between turns. They
/// meet here instead, at the level of a finished answer, so the panel never
/// learns which one it is talking to.
public protocol Reasoner: Sendable {
    func run(_ prompt: String, confirmDestructive: Bool) async throws -> Outcome
}

extension Agent: Reasoner {}

/// One question, one answer over HTTP.
public protocol ModelClient: Sendable {
    func ask(messages: [[String: Any]], tools: [[String: Any]]) async throws -> Turn
}

extension Client: ModelClient {}

public enum Backends {
    /// Whatever is configured right now, ready to answer.
    public static func current() -> any Reasoner {
        switch Settings.backend {
        case .apple:
            if #available(macOS 26.0, *), AppleClient.isAvailable { return AppleAgent() }
            // Configured for Apple on a Mac that cannot run it. Settings says so
            // plainly; falling through here keeps the panel from throwing instead.
            return Agent(client: Client(endpoint: Settings.endpoint))
        case .localModel, .orbio:
            return Agent(client: Client(endpoint: Settings.endpoint))
        }
    }

    /// Load whichever model is configured, so the first question is not the slow
    /// one. Safe to call when nothing needs loading.
    public static func prewarm() {
        guard Settings.backend == .apple, #available(macOS 26.0, *) else { return }
        AppleClient.prewarm()
    }
}
