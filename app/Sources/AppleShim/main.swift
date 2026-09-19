import CeleritasKit
import Foundation
import Network

// Apple Intelligence behind an OpenAI-shaped endpoint, so the benchmark can score
// it against the same 55 tasks, the same simulated Mac and the same verifiers as
// every other model. A Swift reimplementation of the harness would be a different
// measurement wearing the same name.
//
//     .build/debug/AppleShim &
//     CELERITY_BASE=http://127.0.0.1:8139/v1 CELERITY_KEY=none \
//       python3 bench/run.py --model apple-intelligence --split dev

let port: UInt16 = 8139

/// One at a time. Apple's model is a single on-device resource, and overlapping
/// sessions turn a latency measurement into a measurement of contention.
@available(macOS 26.0, *)
actor Gate {
    static let shared = Gate()

    /// Takes bytes rather than dictionaries. A `[[String: Any]]` is not Sendable
    /// and cannot cross into an actor, so the request is parsed on this side.
    func ask(body: Data) async throws -> Turn {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return try await AppleClient.askOnce(
            messages: json["messages"] as? [[String: Any]] ?? [],
            tools: json["tools"] as? [[String: Any]] ?? [])
    }
}

func reply(_ turn: Turn) -> [String: Any] {
    var message: [String: Any] = ["role": "assistant", "content": turn.text ?? NSNull()]
    if let tool = turn.tool {
        let arguments = (try? JSONSerialization.data(withJSONObject: turn.arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        message["tool_calls"] = [["id": "call_0", "type": "function",
                                  "function": ["name": tool, "arguments": arguments]]]
    }
    return ["id": "apple", "object": "chat.completion", "model": "apple-intelligence",
            "choices": [["index": 0, "message": message,
                         "finish_reason": turn.tool == nil ? "stop" : "tool_calls"]],
            // No tokens and no price. Reporting a made up number here would put a
            // fiction straight into the results table.
            "usage": ["cost": 0.0]]
}

func http(_ status: Int, _ body: [String: Any]) -> Data {
    let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    let head = """
        HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r
        Content-Type: application/json\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
    return Data(head.utf8) + payload
}

final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return data }
    func append(_ more: Data) { lock.lock(); defer { lock.unlock() }; data.append(more) }
}

func handle(_ connection: NWConnection) {
    connection.start(queue: .global())
    // A box rather than a captured var: the receive handler runs on the network
    // queue and Swift 6 will not let a concurrent closure mutate a local.
    let buffer = Buffer()

    @Sendable func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            chunk, _, done, error in
            if let chunk { buffer.append(chunk) }
            if error != nil { connection.cancel(); return }

            // Wait for the headers, then for as many body bytes as they promise.
            let bytes = buffer.bytes
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if done { connection.cancel() } else { readMore() }
                return
            }
            let header = String(decoding: bytes[..<split.lowerBound], as: UTF8.self)
            let length = header.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = bytes[split.upperBound...]
            if body.count < length {
                if done { connection.cancel() } else { readMore() }
                return
            }

            let payload = Data(body.prefix(length))

            Task {
                let response: Data
                if #available(macOS 26.0, *) {
                    do {
                        let turn = try await Gate.shared.ask(body: payload)
                        response = http(200, reply(turn))
                    } catch {
                        response = http(500, ["error": ["message": "\(error)"]])
                    }
                } else {
                    response = http(500, ["error": ["message": "needs macOS 26"]])
                }
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
    readMore()
}

// A top level `guard #available` does not narrow what follows it, so the startup
// lives in a function that carries the availability itself.
@available(macOS 26.0, *)
func serve() throws {
    if let reason = AppleClient.unavailableReason {
        FileHandle.standardError.write(Data("\(reason)\n".utf8)); exit(1)
    }
    let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    listener.newConnectionHandler = handle
    listener.start(queue: .main)
    AppleClient.prewarm()
    print("apple-intelligence shim on http://127.0.0.1:\(port)/v1")
    RunLoop.main.run()
}

if #available(macOS 26.0, *) {
    try serve()
} else {
    FileHandle.standardError.write(Data("needs macOS 26\n".utf8)); exit(1)
}
