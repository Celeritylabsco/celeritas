import Foundation

/// Currency conversion, from a table the lab publishes.
///
/// Unlike every other conversion in the app this one needs the network, once.
/// The whole rate table is downloaded and the arithmetic happens here, so the
/// lab never learns which pair somebody asked for, and the feature keeps
/// working on a plane.
///
/// Every rate carries its own date, and they genuinely differ: some central
/// banks publish daily and others lag by a day or two. Every answer prints the
/// date of the rate it used, because an exchange rate with no date is a number
/// someone might act on.
public enum Currency {
    public struct Rate: Codable, Sendable, Equatable {
        public let rate: Double
        public let date: String

        // Spelled out because the generated memberwise init is internal, and the
        // tests build a table from another module.
        public init(rate: Double, date: String) {
            self.rate = rate
            self.date = date
        }
    }

    public struct Table: Codable, Sendable {
        public let base: String
        public let rates: [String: Rate]

        public init(base: String, rates: [String: Rate]) {
            self.base = base
            self.rates = rates
        }
    }

    public struct Answer: Sendable, Equatable {
        /// "15,706 JPY"
        public let value: String
        /// "100 USD  =  15,706 JPY"
        public let line: String
        /// "rate from 19 Sep"
        public let asOf: String
    }

    /// What the app has on disk, whatever its age.
    public static func table() -> Table? {
        LabAPI.cached("rates", as: Table.self)?.data
    }

    /// Pull a fresh table if the cached one is past its life. Called at launch
    /// and never from the palette, which must not wait on a network call.
    public static func refreshIfStale() async {
        let held = LabAPI.cached("rates", as: Table.self)
        guard held == nil || LabAPI.isStale(held!) else { return }
        _ = await LabAPI.refresh("rates", as: Table.self)
    }

    /// `100 usd in eur`, `50 gbp to usd`, `20 chf jpy`.
    ///
    /// A target is required. Unlike metres and miles, no currency has an obvious
    /// other side, and guessing one would put a number in front of someone that
    /// they did not ask for.
    public static func convert(_ input: String, using table: Table?) -> Answer? {
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { return nil }

        var body = text
        var targetName: String?
        for word in [" in ", " to ", " into ", ">"] {
            guard let range = body.range(of: word, options: .backwards) else { continue }
            targetName = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            break
        }

        if targetName == nil {
            // "20 chf jpy", with no joining word. The doc comment above has
            // promised this since the file was written and the code never did
            // it. The routing suite caught it on 19 Sep 2026.
            //
            // Safe because the last word has to be a currency code we know.
            // "5 km" and "100 usd" both fall through: km is not a code, and
            // dropping "usd" off "100 usd" leaves no source currency.
            let parts = body.split(separator: " ").map(String.init)
            if parts.count >= 2, code(parts[parts.count - 1]) != nil {
                targetName = parts[parts.count - 1]
                body = parts.dropLast().joined(separator: " ")
            }
        }

        guard let (amount, fromName) = split(body) else { return nil }
        // Both sides have to be currency codes before this claims the query.
        // "3 miles in km" must reach the unit converter untouched.
        guard let from = code(fromName), let target = targetName, let to = code(target),
              from != to
        else { return nil }

        // Codes are recognised before the table is consulted, so someone typing
        // a real conversion on first run is told what is missing rather than
        // getting silence.
        guard let table else {
            return Answer(value: "Rates not downloaded yet",
                          line: "\(format(amount)) \(from) to \(to)",
                          asOf: "connect once to fetch them")
        }
        guard let converted = exchange(amount, from: from, to: to, table: table) else {
            let absent = has(from, table) ? to : from
            return Answer(value: "No rate for \(absent)",
                          line: "\(format(amount)) \(from) to \(to)",
                          asOf: "not in the published table")
        }

        let dates = [table.rates[from]?.date, table.rates[to]?.date].compactMap { $0 }
        return Answer(value: "\(format(converted.0)) \(to)",
                      line: "\(format(amount)) \(from)  =  \(format(converted.0)) \(to)",
                      asOf: "rate from \(pretty(dates.min() ?? converted.1))")
    }

    /// The base has no row of its own, so a plain dictionary lookup reports it
    /// as the missing side of every pair.
    static func has(_ code: String, _ table: Table) -> Bool {
        code == table.base || table.rates[code] != nil
    }

    /// Through the table's base, which is the only pair every rate shares.
    static func exchange(_ value: Double, from: String, to: String,
                         table: Table) -> (Double, String)? {
        let base = table.base
        func perBase(_ code: String) -> Rate? {
            code == base ? Rate(rate: 1, date: table.rates.values.first?.date ?? "")
                         : table.rates[code]
        }
        guard let source = perBase(from), let destination = perBase(to),
              source.rate > 0 else { return nil }
        return (value / source.rate * destination.rate, destination.date)
    }

    /// Codes only, and only ones the table knows. Accepting names would collide
    /// with far too much: "won", "rand" and "real" are all ordinary words.
    static let known: Set<String> = [
        "usd", "eur", "gbp", "ngn", "jpy", "cny", "inr", "cad", "aud", "chf",
        "zar", "kes", "ghs", "egp", "mad", "aed", "sar", "brl", "mxn", "ars",
        "sgd", "hkd", "krw", "nzd", "sek", "nok", "dkk", "pln", "try", "rub",
        "idr", "myr", "thb", "php", "vnd", "pkr", "bdt", "uah", "czk", "huf",
    ]

    static func code(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        return known.contains(trimmed) ? trimmed.uppercased() : nil
    }

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

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 10_000 ? 0 : 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "2026-09-19" reads as noise beside a number. "19 Sep" does not.
    static func pretty(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "d MMM"
        return out.string(from: date)
    }
}
