import Foundation

public struct Turn: Sendable {
    public let tool: String?
    public let arguments: [String: String]
    public let text: String?
    public let seconds: Double
    public let cost: Double?
}

public enum ClientError: Error, LocalizedError {
    case transport(String)

    public var errorDescription: String? {
        switch self { case .transport(let message): return message }
    }
}

/// One OpenAI-shaped client. Nothing in it is specific to any provider.
public struct Client: Sendable {
    let endpoint: Endpoint
    let timeout: TimeInterval

    public init(endpoint: Endpoint, timeout: TimeInterval = 60) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public func ask(messages: [[String: Any]], tools: [[String: Any]]) async throws -> Turn {
        var request = URLRequest(url: URL(string: "\(endpoint.baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": endpoint.model,
            "temperature": 0,
            "max_tokens": 400,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
        ])

        // A private ephemeral session, so a request never touches the shared cache.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession(configuration: config).data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
        let seconds = Date().timeIntervalSince(started)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw ClientError.transport("http \(http.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let choice = (json["choices"] as? [[String: Any]])?.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        let usage = json["usage"] as? [String: Any]

        guard let calls = message["tool_calls"] as? [[String: Any]], let first = calls.first,
              let function = first["function"] as? [String: Any]
        else {
            return Turn(tool: nil, arguments: [:], text: message["content"] as? String,
                        seconds: seconds, cost: usage?["cost"] as? Double)
        }

        // Some providers namespace the tool they chose, returning
        // `default_api.battery_status`. That is the right tool with a prefix on it.
        let name = (function["name"] as? String ?? "").split(separator: ".").last.map(String.init)
        var arguments: [String: String] = [:]
        if let raw = function["arguments"] as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            for (key, value) in parsed { arguments[key] = String(describing: value) }
        }
        return Turn(tool: name, arguments: arguments, text: message["content"] as? String,
                    seconds: seconds, cost: usage?["cost"] as? Double)
    }
}
