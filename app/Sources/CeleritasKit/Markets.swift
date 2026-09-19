import Foundation

/// Share and coin prices, from the tables the lab publishes.
///
/// Two feeds, because the two markets are not alike. Shares come from an end of
/// day source, so a price is a close with the session it closed on, which is
/// most of what exists for equities anyway since the market shuts. Coins trade
/// through the night and a weekend, so those are live and carry the minute they
/// were read. Every row says which it is, because a stale price shown as a live
/// one is the only mistake in this app that could cost somebody real money.
///
/// The share table is large, around eight thousand tickers, so both are decoded
/// once and kept. Reading half a megabyte off disk on every keystroke would
/// make typing stutter.
public actor Markets {
    public static let shared = Markets()

    /// One share. Short keys because there are thousands of them.
    public struct Row: Codable, Sendable, Equatable {
        /// Close.
        public let c: Double
        /// Percent change against the session before. Absent when unknown.
        public let p: Double?
        /// Company name. Absent for tickers the reference feed omits.
        public let n: String?

        public init(c: Double, p: Double? = nil, n: String? = nil) {
            self.c = c
            self.p = p
            self.n = n
        }
    }

    /// One coin. Live, so it carries a timestamp and the day's range.
    public struct Coin: Codable, Sendable, Equatable {
        public let c: Double
        public let p: Double?
        public let n: String?
        /// 24 hour high and low.
        public let h: Double?
        public let l: Double?
        /// "2026-09-19 14:07:04", the moment the price was read.
        public let t: String?

        public init(c: Double, p: Double? = nil, n: String? = nil,
                    h: Double? = nil, l: Double? = nil, t: String? = nil) {
            self.c = c
            self.p = p
            self.n = n
            self.h = h
            self.l = l
            self.t = t
        }
    }

    public struct Shares: Codable, Sendable {
        public let asOf: String
        public let stocks: [String: Row]

        enum CodingKeys: String, CodingKey {
            case stocks
            case asOf = "as_of"
        }

        public init(asOf: String, stocks: [String: Row]) {
            self.asOf = asOf
            self.stocks = stocks
        }
    }

    public struct Coins: Codable, Sendable {
        public let asOf: String
        public let coins: [String: Coin]

        enum CodingKeys: String, CodingKey {
            case coins
            case asOf = "as_of"
        }

        public init(asOf: String, coins: [String: Coin]) {
            self.asOf = asOf
            self.coins = coins
        }
    }

    public struct Quote: Sendable, Equatable {
        /// "81,288.44"
        public let value: String
        /// "BTC  81,288.44 USD  +0.23%"
        public let line: String
        /// "Bitcoin, live 14:07" or "Apple Inc., close 18 Sep"
        public let asOf: String
    }

    private var shares: Shares?
    private var coins: Coins?
    /// The currency table, held here too so a conversion can cross all three
    /// without decoding a file on every keystroke.
    private var fiat: Currency.Table?
    private var names: [String: String] = [:]
    private var loaded = false

    /// Decode once. Called from the palette, so it must not touch the network.
    private func load() {
        guard !loaded else { return }
        adopt(shares: LabAPI.cached("markets", as: Shares.self)?.data,
              coins: LabAPI.cached("crypto", as: Coins.self)?.data,
              fiat: Currency.table())
    }

    /// Take the tables and index their names. Also the way the tests get tables
    /// in without files on disk.
    public func adopt(shares incomingShares: Shares?, coins incomingCoins: Coins?,
                      fiat incomingFiat: Currency.Table? = nil) {
        loaded = true
        shares = incomingShares
        coins = incomingCoins
        fiat = incomingFiat
        names = [:]
        // Coins first, so a name claimed by both belongs to the live side.
        for (symbol, coin) in incomingCoins?.coins ?? [:] {
            index(coin.n, as: symbol)
        }
        for (symbol, row) in incomingShares?.stocks ?? [:] {
            index(row.n, as: symbol)
        }
    }

    /// Name to symbol, so "tesla" finds TSLA. Built once rather than searched
    /// each time, because scanning eight thousand names per keystroke is the
    /// same problem as decoding the file per keystroke.
    private func index(_ name: String?, as symbol: String) {
        guard let name else { return }
        for spelling in Self.spellings(of: name) where names[spelling] == nil {
            names[spelling] = symbol
        }
    }

    /// Drop the decoded copies so the next lookup picks up newer files.
    public func invalidate() {
        loaded = false
        shares = nil
        coins = nil
        fiat = nil
        names = [:]
    }

    /// Pull whichever table is past its life. Called at launch and on a timer,
    /// never from the palette.
    public static func refreshIfStale() async {
        var changed = false
        if LabAPI.cached("markets", as: Shares.self).map(LabAPI.isStale) ?? true {
            changed = await LabAPI.refresh("markets", as: Shares.self) != nil
        }
        if LabAPI.cached("crypto", as: Coins.self).map(LabAPI.isStale) ?? true {
            changed = (await LabAPI.refresh("crypto", as: Coins.self) != nil) || changed
        }
        if changed { await Markets.shared.invalidate() }
    }

    /// `btc`, `aapl`, `$f`, `tsla price`, `tesla`, `bitcoin`.
    ///
    /// Usually one answer, sometimes two. Twenty one symbols are a US listed
    /// company and a coin at once: DASH is DoorDash and Dash, STX is Seagate
    /// and Stacks, CAKE is the Cheesecake Factory and PancakeSwap. The two
    /// feeds report no comparable volume, so picking one would be a coin flip
    /// dressed as a decision. Both are offered and each says what it is.
    public func quotes(for input: String) -> [Quote] {
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32 else { return [] }
        load()
        guard shares != nil || coins != nil else { return [] }

        guard let (symbol, explicit) = candidate(in: text) else { return [] }

        // Saying "$f" or "f price" is an explicit statement that a ticker is
        // meant, so one and two letter tickers are only reachable those ways.
        // Otherwise every short word in the language is a ticker: "it", "on",
        // "all", "key", "cat" and "a" are all real ones, and they would bury
        // everything else a launcher has to offer.
        guard explicit || symbol.count >= 3 || names[symbol] != nil else { return [] }

        for found in [symbol.uppercased(), names[symbol] ?? ""] where !found.isEmpty {
            var out: [Quote] = []
            // The coin leads. It is the live number, and a name that resolved
            // through the index resolved to whichever side owns that name.
            if let coin = coins?.coins[found] {
                out.append(Self.quote(found, coin))
            }
            if let row = shares?.stocks[found], let asOf = shares?.asOf {
                out.append(Self.quote(found, row, asOf))
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    /// The first answer, for callers that only want one.
    public func quote(for input: String) -> Quote? { quotes(for: input).first }

    /// A few real coins for the tips window to show.
    ///
    /// Live numbers off the cache rather than an illustration. A page that says
    /// "you can check crypto here" is a claim; the same page showing what
    /// Bitcoin did in the last day is the feature working in front of you.
    /// Empty before the first fetch, and the view draws nothing in that case.
    public struct Highlight: Sendable, Identifiable {
        public let symbol: String
        public let name: String
        public let price: String
        public let change: Double?
        public let at: String
        public var id: String { symbol }
    }

    public func highlights(_ symbols: [String] = ["BTC", "ETH", "SOL"]) -> [Highlight] {
        load()
        return symbols.compactMap { symbol in
            guard let coin = coins?.coins[symbol] else { return nil }
            return Highlight(symbol: symbol, name: coin.n ?? symbol,
                             price: Self.money(coin.c), change: coin.p,
                             at: Self.clock(coin.t))
        }
    }

    public struct Conversion: Sendable, Equatable {
        /// "23.6 SOL"
        public let value: String
        /// "1 ETH  =  23.6 SOL"
        public let line: String
        /// "live 14:07", or the stalest side when one of them is not live.
        public let asOf: String
    }

    /// How current a side of a conversion is. Ordered stalest last, because an
    /// answer is only as fresh as the oldest number that went into it.
    enum Freshness: Comparable {
        case live(String)
        case rate(String)
        case close(String)

        var rank: Int {
            switch self {
            case .live: return 0
            case .rate: return 1
            case .close: return 2
            }
        }

        var label: String {
            switch self {
            case .live(let at): return "live \(at)"
            case .rate(let day): return "rate \(Currency.pretty(day))"
            case .close(let day): return "close \(Currency.pretty(day))"
            }
        }

        static func < (a: Freshness, b: Freshness) -> Bool { a.rank < b.rank }
    }

    /// `1 eth to sol`, `0.5 btc in usd`, `1 aapl in btc`, `500 gbp in eth`.
    ///
    /// Anything against anything, because the lab publishes all three tables.
    /// Every side is turned into dollars and the arithmetic happens there, so a
    /// share, a coin and a currency are comparable without a special case for
    /// each pairing.
    ///
    /// Worth doing here rather than leaving to a model, which was the state of
    /// things until one answered "1 eth to sol" with 66. It called no tool,
    /// used prices it half remembered, and was out by nearly three times. Both
    /// numbers were sitting in this cache at the time.
    ///
    /// The tag names the stalest side. Mixing a live coin with a share means
    /// the answer is as old as that session's close, and saying "live" over it
    /// would be the same lie in a smaller font.
    public func convert(_ input: String) -> Conversion? {
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { return nil }
        load()

        var body = text
        var targetName: String?
        for word in [" in ", " to ", " into ", ">"] {
            guard let range = body.range(of: word, options: .backwards) else { continue }
            targetName = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let target = targetName,
              let (amount, fromName) = Self.split(body),
              let from = resolve(fromName), let to = resolve(target),
              from.symbol != to.symbol,
              from.usd > 0, to.usd > 0,
              // Currency to currency belongs to the rates table, which has
              // ninety eight central banks behind it and says so. Claiming it
              // here would put two rows on screen for one question.
              !(from.isMoney && to.isMoney)
        else { return nil }

        let converted = amount * from.usd / to.usd
        let stalest = max(from.fresh, to.fresh)
        return Conversion(
            value: "\(Self.money(converted)) \(to.symbol)",
            line: "\(Self.money(amount)) \(from.symbol)  =  \(Self.money(converted)) \(to.symbol)",
            asOf: stalest.label)
    }

    /// One unit of something, in dollars, and how current that is.
    ///
    /// Currency first: a three letter code that is a currency is almost always
    /// meant as one, and a handful of them are also share tickers somewhere.
    /// Then coins, then shares, matching how a bare symbol resolves.
    private func resolve(_ name: String) -> (symbol: String, usd: Double,
                                             fresh: Freshness, isMoney: Bool)? {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: " $"))
        guard !trimmed.isEmpty else { return nil }

        if let fiat = fiatInDollars(trimmed) {
            return (fiat.0, fiat.1, .rate(fiat.2), true)
        }
        for key in [trimmed.uppercased(), names[trimmed] ?? ""] where !key.isEmpty {
            if let coin = coins?.coins[key] {
                return (key, coin.c, .live(Self.clock(coins?.asOf)), false)
            }
            if let row = shares?.stocks[key], let day = shares?.asOf {
                return (key, row.c, .close(day), false)
            }
        }
        return nil
    }

    /// A currency, in dollars. The published table is USD based, so a row holds
    /// how many of that currency one dollar buys, and this wants the inverse.
    private func fiatInDollars(_ name: String) -> (String, Double, String)? {
        if ["usd", "dollar", "dollars", "$"].contains(name) {
            let day = fiat?.rates.values.first?.date ?? ""
            return ("USD", 1, day)
        }
        guard let table = fiat, let rate = table.rates[name.uppercased()], rate.rate > 0
        else { return nil }
        return (name.uppercased(), 1 / rate.rate, rate.date)
    }

    /// "1 eth" to (1, "eth"). Digits then the rest, commas ignored.
    static func split(_ text: String) -> (Double, String)? {
        var digits = ""
        var rest = ""
        var seen = false
        for character in text {
            if !seen, character.isNumber || character == "." || character == "," {
                if character != "," { digits.append(character) }
            } else if character == " " && !seen && digits.isEmpty {
                continue
            } else {
                seen = true
                rest.append(character)
            }
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, !name.isEmpty, let value = Double(digits) else { return nil }
        return (value, name)
    }

    /// The symbol a query is asking about, and whether it was written in a way
    /// that says a ticker is meant. Nil when the query is about something else.
    func candidate(in text: String) -> (String, Bool)? {
        var body = text
        // Saying "price" is as clear a statement that a ticker is meant as
        // writing a dollar sign, so both count as explicit.
        var said = false
        for word in Self.trailing where body.hasSuffix(" " + word) {
            body = String(body.dropLast(word.count + 1))
            said = true
            break
        }
        for word in Self.leading where body.hasPrefix(word + " ") {
            body = String(body.dropFirst(word.count + 1))
            said = true
            break
        }
        body = body.trimmingCharacters(in: .whitespaces)

        if body.hasPrefix("$") {
            body = String(body.dropFirst())
            said = true
        }
        guard !body.isEmpty, body.count <= 20 else { return nil }
        // A multi word query is only ever a company or coin name, never a
        // ticker, and it has to be one we know. Without this a price turns up
        // under "what should i have for lunch".
        if body.contains(" ") {
            return names[body] != nil ? (body, said) : nil
        }
        // 1INCH is a real ticker, so digits are allowed, but a bare number is
        // arithmetic and belongs to the calculator.
        guard body.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              body.contains(where: \.isLetter)
        else { return nil }
        return (body, said)
    }

    static let trailing = ["price", "stock", "share", "shares", "quote", "ticker", "coin"]
    static let leading = ["price of", "stock", "ticker", "quote for", "price"]

    /// The ways somebody might type a name. "Apple Inc." should be reachable as
    /// "apple", and "Tesla, Inc." as "tesla".
    static func spellings(of name: String) -> [String] {
        let lower = name.lowercased()
        var trimmed = lower
        for suffix in [" inc.", " inc", " corp.", " corp", " corporation", " company",
                       " co.", " plc", " ltd.", " ltd", " s.a.", " n.v.", " ag",
                       " holdings", " group", " limited", " class a", " class b",
                       " common stock", ", inc.", ", inc"] {
            while trimmed.hasSuffix(suffix) {
                trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        var out = [lower]
        if trimmed != lower, !trimmed.isEmpty { out.append(trimmed) }
        return out
    }

    static func quote(_ symbol: String, _ coin: Coin) -> Quote {
        let price = money(coin.c)
        var line = "\(symbol)  \(price) USD"
        if let change = coin.p { line += signed(change) }
        var about = "live \(clock(coin.t))"
        if let name = coin.n { about = "\(name), " + about }
        return Quote(value: price, line: line, asOf: about)
    }

    static func quote(_ symbol: String, _ row: Row, _ date: String) -> Quote {
        let price = money(row.c)
        var line = "\(symbol)  \(price)"
        if let change = row.p { line += signed(change) }
        var about = "close \(Currency.pretty(date))"
        if let name = row.n { about = "\(name), " + about }
        return Quote(value: price, line: line, asOf: about)
    }

    static func signed(_ change: Double) -> String {
        String(format: "  %@%.2f%%", change >= 0 ? "+" : "", change)
    }

    /// Prices here span eleven orders of magnitude, from Pepe at 0.00000383 to
    /// a bitcoin at 81,288. A fixed number of decimals prints one of those two
    /// as zero, so anything under a cent switches to significant digits.
    static func money(_ value: Double) -> String {
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
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "2026-09-19 14:07:04" to "14:07". The date is dropped because a live
    /// price is from today by definition, and the minute is the useful part.
    static func clock(_ stamp: String?) -> String {
        guard let stamp, stamp.count >= 16 else { return "just now" }
        return String(stamp.dropFirst(11).prefix(5))
    }
}
