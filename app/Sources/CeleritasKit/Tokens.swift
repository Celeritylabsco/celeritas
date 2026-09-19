import Foundation

/// Any token, by address or by name, through the lab.
///
/// The other market data is a file the lab builds for everybody. This cannot
/// be, because nobody can precompute a price for a token nobody has pasted yet,
/// so it is the one thing in the app that asks a question and waits.
///
/// It still never blocks the palette. A lookup runs behind the field and the
/// results appear when they land, and everything already known answers from
/// memory in the meantime.
public actor Tokens {
    public static let shared = Tokens()

    /// How long a price is treated as current, matching the lab's own cache.
    /// A token price is a glance, not a trading screen.
    public static let freshFor: TimeInterval = 300

    public struct Token: Codable, Sendable, Equatable, Identifiable {
        public let address: String
        public let symbol: String
        public let name: String
        public let chain: String
        public let price: Double
        public let change24h: Double?
        public let liquidity: Double
        public let fdv: Double?
        public let pools: Int
        public let holders: Int?
        public var id: String { chain + ":" + address }

        public init(address: String, symbol: String, name: String, chain: String,
                    price: Double, change24h: Double? = nil, liquidity: Double = 0,
                    fdv: Double? = nil, pools: Int = 0, holders: Int? = nil) {
            self.address = address
            self.symbol = symbol
            self.name = name
            self.chain = chain
            self.price = price
            self.change24h = change24h
            self.liquidity = liquidity
            self.fdv = fdv
            self.pools = pools
            self.holders = holders
        }
    }

    struct Answer: Codable, Sendable {
        let query: String
        let matches: [Token]
    }

    private var answers: [String: (matches: [Token], at: Date)] = [:]
    private var inFlight: Set<String> = []
    private var restored = false

    /// Pinned prices, kept on disk between launches.
    ///
    /// Memory alone means the strip is blank for a second every time the app
    /// starts, and a price that flickers in is worse than one that is a few
    /// minutes old and says so. Only pins are written: everything else is a
    /// one-off lookup nobody will ask for twice.
    struct Saved: Codable {
        let matches: [Token]
        let at: Date
    }

    private static var file: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = root.appendingPathComponent("Celeritas/api", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory.appendingPathComponent("pinned-tokens.json")
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        guard let data = try? Data(contentsOf: Self.file),
              let held = try? JSONDecoder().decode([String: Saved].self, from: data)
        else { return }
        for (key, saved) in held where answers[key] == nil {
            answers[key] = (saved.matches, saved.at)
        }
    }

    private func save() {
        var out: [String: Saved] = [:]
        for address in Settings.watchedTokens {
            let key = Self.key(address)
            guard let held = answers[key] else { continue }
            out[key] = Saved(matches: held.matches, at: held.at)
        }
        guard let data = try? JSONEncoder().encode(out) else { return }
        try? data.write(to: Self.file)
    }

    /// Anything already known for this query. Instant, so the palette can build
    /// a result list without waiting on anything.
    public func cached(_ query: String) -> [Token] {
        restore()
        return answers[Self.key(query)]?.matches ?? []
    }

    /// How old the held answer is, so a row can say when it is not current.
    public func age(_ query: String) -> TimeInterval? {
        restore()
        guard let held = answers[Self.key(query)] else { return nil }
        return Date().timeIntervalSince(held.at)
    }

    /// Whether this looks like somebody asking about a token at all.
    ///
    /// A launcher must not fire a network request at every keystroke. An
    /// address is unambiguous. Otherwise the person has to say the word, which
    /// also keeps "safari" and "settings" off the wire.
    public nonisolated static func wanted(in input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked before lowercasing. Solana is base58 and case carries meaning
        // there, so folding it makes a real address unfindable. EVM is hex, so
        // case means nothing and folding keeps one cache entry per token.
        if isAddress(raw) { return raw.hasPrefix("0x") ? raw.lowercased() : raw }
        let text = raw.lowercased()
        guard !text.isEmpty, text.count <= 64 else { return nil }
        for word in [" price", " token", " chart"] where text.hasSuffix(word) {
            let stem = String(text.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
            return stem.count >= 2 ? stem : nil
        }
        for word in ["token ", "price of "] where text.hasPrefix(word) {
            let stem = String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
            return stem.count >= 2 ? stem : nil
        }
        return nil
    }

    /// An EVM address, or a Solana one.
    ///
    /// Solana is base58, which drops 0, O, I and l so they cannot be confused
    /// by eye, and runs 32 to 44 characters. Nothing that long is typed into a
    /// launcher by accident, so both can be treated as an exact address and go
    /// straight to the lookup without anybody saying the word "price".
    public nonisolated static func isAddress(_ text: String) -> Bool {
        if text.count == 42, text.hasPrefix("0x"),
           text.dropFirst(2).allSatisfy(\.isHexDigit) { return true }
        guard (32...44).contains(text.count) else { return false }
        return text.allSatisfy(base58.contains)
    }

    private static let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func key(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Solana address keeps its case, everything else folds, so "ORBIO"
        // and "orbio" share one cache entry and an address stays findable.
        return isAddress(trimmed) && !trimmed.hasPrefix("0x") ? trimmed : trimmed.lowercased()
    }

    /// Fetch unless the answer is young or the same request is already out.
    ///
    /// Returns true when something changed, so the caller knows whether it is
    /// worth rebuilding the list.
    @discardableResult
    public func lookup(_ query: String, maxAge: TimeInterval = freshFor) async -> Bool {
        let key = Self.key(query)
        restore()
        guard !key.isEmpty, !inFlight.contains(key) else { return false }
        if let held = answers[key], Date().timeIntervalSince(held.at) < maxAge { return false }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        var parts = URLComponents(string: LabAPI.base + "/token")
        parts?.queryItems = [URLQueryItem(name: "q", value: key)]
        guard let url = parts?.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Celeritas", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(LabAPI.Envelope<Answer>.self, from: data)
        else { return false }

        answers[key] = (decoded.data.matches, Date())
        if Settings.isWatched(key) { save() }
        return true
    }

    /// A watched token by its bare symbol or name, straight from memory.
    ///
    /// This is what adding a token buys. Before it, ORBIO needs "orbio price"
    /// so the launcher knows a token is meant and is worth a network call.
    /// Once it is watched the name is known, so typing "orbio" answers
    /// instantly and offline, exactly like "btc" does. Pinning is separate and
    /// only decides what sits on the empty screen.
    public func watchedMatch(_ query: String) -> [Token] {
        restore()
        let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 32 else { return [] }
        return watched().filter {
            let symbol = $0.symbol.lowercased(), name = $0.name.lowercased()
            return symbol == text || name == text || name.hasPrefix(text + " ")
        }
    }

    /// Every token the person added.
    public func watched() -> [Token] {
        restore()
        return Settings.watchedTokens.compactMap { address in
            answers[Self.key(address)]?.matches.first
        }
    }

    /// The subset shown on the empty screen.
    public func pinned() -> [Token] {
        restore()
        return Settings.pinnedTokens.compactMap { address in
            answers[Self.key(address)]?.matches.first
        }
    }

    @discardableResult
    public func refreshWatched(maxAge: TimeInterval = freshFor) async -> Bool {
        var changed = false
        for address in Settings.watchedTokens {
            if await lookup(address, maxAge: maxAge) { changed = true }
        }
        if changed { save() }
        return changed
    }

    /// Add a token and fetch it, so adding works even for an address that was
    /// typed rather than found in a result row.
    @discardableResult
    public func addAndFetch(_ address: String, pin: Bool = false) async -> Token? {
        Settings.addToken(address)
        if pin { Settings.setPinned(address, true) }
        await lookup(address, maxAge: 0)
        save()
        return answers[Self.key(address)]?.matches.first
    }

    /// "$0.0527" or "$1,234.56". Prices here run from a fraction of a cent to
    /// thousands, so the decimals follow the number.
    public nonisolated static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        if abs(value) < 0.01, value != 0 {
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = 3
            formatter.maximumFractionDigits = 18
        } else {
            formatter.maximumFractionDigits = value >= 1000 ? 2 : 4
        }
        return "$" + (formatter.string(from: NSNumber(value: value)) ?? String(value))
    }

    /// "$1.7m". Liquidity is how the real token is told from the copy of it,
    /// so it goes on every row.
    public nonisolated static func short(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "$%.1fb", value / 1_000_000_000)
        case 1_000_000...:     return String(format: "$%.1fm", value / 1_000_000)
        case 1_000...:         return String(format: "$%.0fk", value / 1_000)
        default:               return String(format: "$%.0f", value)
        }
    }
}
