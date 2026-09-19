import Foundation

/// What Celeritas can do, written once.
///
/// The empty state shows a handful and the tips window shows all of them, from
/// this list. Two hand-maintained lists of examples disagree within a week, and
/// the one nobody looks at is the one that goes stale.
public enum Examples {
    /// Whether a line costs anything to answer. This is the distinction worth
    /// teaching first: almost everything here never reaches a model.
    public enum Cost: Sendable {
        /// Answered on the machine from the index. No model, no network, no money.
        case instant
        /// Goes to whichever model is configured.
        case model
    }

    public struct Example: Sendable, Identifiable {
        public let query: String
        public let does: String
        public let cost: Cost
        public var id: String { query }
    }

    public struct Group: Sendable, Identifiable {
        public let title: String
        public let examples: [Example]
        public var id: String { title }
    }

    static func i(_ q: String, _ d: String) -> Example { .init(query: q, does: d, cost: .instant) }
    static func m(_ q: String, _ d: String) -> Example { .init(query: q, does: d, cost: .model) }

    /// Coins lead. Opening an app is what everybody already expects a launcher
    /// to do, and needs no teaching. A live crypto price in a Spotlight box is
    /// the thing nobody knows is there, so it goes first and gets the room.
    public static let groups: [Group] = [
        Group(title: "Coins, live", examples: [
            i("btc", "Bitcoin, priced to the minute"),
            i("eth", "Ether"),
            i("sol", "Solana"),
            i("xrp", "XRP"),
            i("doge", "Dogecoin"),
            i("chainlink", "Full names work as well as tickers"),
            i("solana", "So does this"),
            i("pepe", "Sub cent coins keep every digit"),
            i("btc price", "Saying price works too"),
            i("$sui", "A dollar sign forces a short ticker"),
        ]),
        Group(title: "Any token, any chain", examples: [
            i("orbio price", "Say price and we look it up"),
            i("0x\u{2026}", "Paste a Robinhood contract address"),
            i("A18Gr\u{2026}", "Or a Solana one"),
            i("command D", "Follow it, so the symbol works offline"),
            i("command P", "Pin it to the empty screen as well"),
            i("orbio", "Once followed, the bare name is enough"),
        ]),
        Group(title: "Convert anything into anything", examples: [
            i("1 eth to sol", "Coin to coin, at live prices"),
            i("0.5 btc in usd", "Coin to dollars"),
            i("2 eth in gbp", "Coin to any currency"),
            i("500 gbp in btc", "And back the other way"),
            i("1 aapl in btc", "Even a share into a coin"),
        ]),
        Group(title: "Shares, at the last close", examples: [
            i("aapl", "Apple, with the day's move"),
            i("nvda", "Any US listed ticker"),
            i("tesla", "Company names too"),
            i("$f", "Ford, and the dollar sign disambiguates"),
            i("dash", "Both DoorDash and Dash, because it is both"),
        ]),
        Group(title: "Work it out", examples: [
            i("5 * 12", "Arithmetic, brackets and powers"),
            i("what is 2 + 2", "Written as a question"),
            i("20c", "Celsius to Fahrenheit"),
            i("5 km", "Kilometres to miles"),
            i("180 lb in kg", "Say the unit you want"),
            i("2gb in mb", "Data sizes, KB and KiB both"),
            i("90 mph in kph", "Speed"),
            i("2h in min", "Time"),
            i("100 usd in eur", "Currency, rates from the lab"),
        ]),
        Group(title: "Emoji", examples: [
            i("fire", "\u{1F525} return copies it"),
            i("rocket", "\u{1F680} 3,963 of them, all offline"),
            i("red heart", "\u{2764}\u{FE0F} two words narrow it down"),
            i(":tada:", "\u{1F389} the colon form works"),
            i("+1", "\u{1F44D} and the shorthand"),
            i("emoji fi", "\u{1F41F}\u{1F525}\u{1F527} say emoji to match part of a word"),
        ]),
        Group(title: "Open things", examples: [
            i("safari", "Open an app by name"),
            i("act mon", "Initials work too"),
            i("settings", "Celeritas settings"),
        ]),
        Group(title: "Check the machine", examples: [
            i("battery", "Charge and whether it is plugged in"),
            i("disk space", "What is free"),
            i("wifi", "The network you are on"),
            i("memory", "Pressure and swap"),
            i("cpu", "What is using it"),
        ]),
        Group(title: "Ask it to do something", examples: [
            m("am i free tomorrow", "Reads your calendar"),
            m("email the team about friday", "Drafts it, asks before sending"),
            m("remind me to call the bank at 4", "Makes a reminder"),
            m("find the invoice from last week", "Searches your files"),
            m("set the volume to 30", "Changes a setting"),
        ]),
    ]

    /// The handful shown on an empty field. Short ones, and a spread across what
    /// the launcher does, so the first screen teaches the range rather than one
    /// corner of it.
    public static let starters: [Example] = [
        i("btc", "Bitcoin, live to the minute"),
        i("1 eth to sol", "Convert anything into anything"),
        i("aapl", "A share at the last close"),
        i("100 usd in eur", "Currency at today's rate"),
        i("20c", "Celsius to Fahrenheit"),
        i("5 * 12", "Arithmetic"),
        i("fire", "\u{1F525} Find an emoji, return copies it"),
        i("safari", "Open an app"),
        m("am i free tomorrow", "Reads your calendar"),
    ]

    /// Everything, flattened, for the tips window.
    public static var all: [Example] { groups.flatMap(\.examples) }

    public static var instantCount: Int { all.filter { $0.cost == .instant }.count }
}
