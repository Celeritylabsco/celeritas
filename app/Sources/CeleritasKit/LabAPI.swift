import Foundation

/// The lab's API, which is the only outside party this app talks to.
///
/// Every integration with a third party lives on the server. Celeritas calls
/// `celeritylabs.co`, the lab calls whoever, and the app ships no third-party
/// key and needs no update when a provider is swapped. Currency is the first
/// thing on it and the shape is deliberately general.
///
/// **The palette never waits on this.** A launcher that pauses for a network
/// call is a broken launcher, so answers come from a file on disk and the
/// refresh happens behind them. First run has no file, which the UI says rather
/// than hiding.
public enum LabAPI {
    public static let base = "https://celeritylabs.co/api/v1"

    /// The envelope every endpoint shares, so freshness can be judged without
    /// knowing what the endpoint is for.
    public struct Envelope<Payload: Codable & Sendable>: Codable, Sendable {
        public let endpoint: String
        public let fetched: String
        public let ttlSeconds: Int
        public let source: String
        public let data: Payload

        enum CodingKeys: String, CodingKey {
            case endpoint, fetched, source, data
            case ttlSeconds = "ttl_seconds"
        }
    }

    static func cacheDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = root.appendingPathComponent("Celeritas/api", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }

    /// Fetch an endpoint and write it to disk. Returns nil rather than throwing,
    /// because nothing here is worth interrupting the person for.
    public static func refresh<Payload>(_ name: String,
                                        as type: Payload.Type) async -> Envelope<Payload>? {
        guard let url = URL(string: "\(base)/\(name).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Celeritas", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Envelope<Payload>.self, from: data)
        else { return nil }

        try? data.write(to: cacheDirectory().appendingPathComponent("\(name).json"))
        return decoded
    }

    /// Whatever was last written, however old. Age is reported rather than used
    /// to hide the answer: a rate from yesterday is worth showing, labelled.
    public static func cached<Payload>(_ name: String,
                                       as type: Payload.Type) -> Envelope<Payload>? {
        let url = cacheDirectory().appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Envelope<Payload>.self, from: data)
    }

    public static func isStale<Payload>(_ envelope: Envelope<Payload>) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let fetched = formatter.date(from: envelope.fetched) else { return true }
        return Date().timeIntervalSince(fetched) > Double(envelope.ttlSeconds)
    }
}
