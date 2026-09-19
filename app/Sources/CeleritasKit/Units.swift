import Foundation

/// Unit conversion on the instant path. No network, no model, no key.
///
/// Every ratio here is fixed and always will be, so this is arithmetic the app
/// can do itself. `20c` answers as fast as `5+5` does. Currency is deliberately
/// absent: a rate changes hourly and needs a live source, so it belongs on a
/// path that can say how old its number is.
///
/// Two conventions are chosen rather than guessed, because both have a wrong
/// answer that looks right:
///
/// - **A gallon is the US one**, 3.785 litres. The imperial gallon is 4.546, a
///   twenty percent difference, and `gal` on its own means different things
///   either side of an ocean. Say `impgal` for the other.
/// - **KB is 1000 bytes and KiB is 1024.** Disk vendors and operating systems
///   have disagreed about this for decades, so neither is inferred.
public enum Units {
    public struct Result: Sendable, Equatable {
        /// What to show: "68 °F".
        public let value: String
        /// The whole line: "20 °C  =  68 °F".
        public let line: String
    }

    enum Kind: String { case temperature, length, mass, volume, speed, data, time }

    /// A unit, as a multiple of its category's base.
    struct Unit {
        let kind: Kind
        let symbol: String
        /// How many base units one of these is. Unused for temperature.
        let ratio: Double
        /// What to convert to when nobody says. Picked as the other side of the
        /// question people are usually asking.
        let partner: String?
    }

    // Base units: celsius, metre, gram, litre, metres per second, byte, second.
    static let table: [String: Unit] = build()

    static func build() -> [String: Unit] {
        var all: [String: Unit] = [:]
        func add(_ names: [String], _ kind: Kind, _ symbol: String,
                 _ ratio: Double, partner: String? = nil) {
            for name in names { all[name] = Unit(kind: kind, symbol: symbol,
                                                 ratio: ratio, partner: partner) }
        }

        add(["c", "celsius", "centigrade", "°c"], .temperature, "°C", 1, partner: "f")
        add(["f", "fahrenheit", "°f"], .temperature, "°F", 1, partner: "c")
        add(["k", "kelvin"], .temperature, "K", 1, partner: "c")

        add(["mm", "millimetre", "millimeter"], .length, "mm", 0.001, partner: "in")
        add(["cm", "centimetre", "centimeter"], .length, "cm", 0.01, partner: "in")
        add(["m", "metre", "meter", "metres", "meters"], .length, "m", 1, partner: "ft")
        add(["km", "kilometre", "kilometer", "kilometres", "kilometers"],
            .length, "km", 1000, partner: "mi")
        add(["in", "inch", "inches"], .length, "in", 0.0254, partner: "cm")
        add(["ft", "foot", "feet"], .length, "ft", 0.3048, partner: "m")
        add(["yd", "yard", "yards"], .length, "yd", 0.9144, partner: "m")
        add(["mi", "mile", "miles"], .length, "mi", 1609.344, partner: "km")
        add(["nmi", "nauticalmile"], .length, "nmi", 1852, partner: "km")

        add(["mg", "milligram"], .mass, "mg", 0.001, partner: "g")
        add(["g", "gram", "grams"], .mass, "g", 1, partner: "oz")
        add(["kg", "kilo", "kilogram", "kilograms"], .mass, "kg", 1000, partner: "lb")
        add(["t", "tonne", "tonnes"], .mass, "t", 1_000_000, partner: "lb")
        add(["oz", "ounce", "ounces"], .mass, "oz", 28.349523125, partner: "g")
        add(["lb", "lbs", "pound", "pounds"], .mass, "lb", 453.59237, partner: "kg")
        add(["st", "stone"], .mass, "st", 6350.29318, partner: "kg")

        add(["ml", "millilitre", "milliliter"], .volume, "ml", 0.001, partner: "floz")
        add(["l", "litre", "liter", "litres", "liters"], .volume, "l", 1, partner: "gal")
        add(["tsp", "teaspoon"], .volume, "tsp", 0.00492892159375, partner: "ml")
        add(["tbsp", "tablespoon"], .volume, "tbsp", 0.01478676478125, partner: "ml")
        add(["floz", "fluidounce"], .volume, "fl oz", 0.0295735295625, partner: "ml")
        add(["cup", "cups"], .volume, "cup", 0.2365882365, partner: "ml")
        add(["pt", "pint", "pints"], .volume, "pt", 0.473176473, partner: "l")
        add(["qt", "quart", "quarts"], .volume, "qt", 0.946352946, partner: "l")
        add(["gal", "gallon", "gallons"], .volume, "gal (US)", 3.785411784, partner: "l")
        add(["impgal", "imperialgallon"], .volume, "gal (imp)", 4.54609, partner: "l")

        add(["mps", "m/s"], .speed, "m/s", 1, partner: "kph")
        add(["kph", "kmh", "km/h"], .speed, "km/h", 0.277777777777778, partner: "mph")
        add(["mph"], .speed, "mph", 0.44704, partner: "kph")
        add(["kn", "knot", "knots"], .speed, "kn", 0.514444444444444, partner: "kph")

        add(["b", "byte", "bytes"], .data, "B", 1, partner: "kb")
        add(["kb", "kilobyte"], .data, "KB", 1000, partner: "mb")
        add(["mb", "megabyte"], .data, "MB", 1e6, partner: "gb")
        add(["gb", "gigabyte"], .data, "GB", 1e9, partner: "mb")
        add(["tb", "terabyte"], .data, "TB", 1e12, partner: "gb")
        add(["kib", "kibibyte"], .data, "KiB", 1024, partner: "kb")
        add(["mib", "mebibyte"], .data, "MiB", 1_048_576, partner: "mb")
        add(["gib", "gibibyte"], .data, "GiB", 1_073_741_824, partner: "gb")
        add(["tib", "tebibyte"], .data, "TiB", 1_099_511_627_776, partner: "tb")

        add(["ms", "millisecond"], .time, "ms", 0.001, partner: "s")
        add(["s", "sec", "secs", "second", "seconds"], .time, "s", 1, partner: "min")
        add(["min", "mins", "minute", "minutes"], .time, "min", 60, partner: "h")
        add(["h", "hr", "hrs", "hour", "hours"], .time, "h", 3600, partner: "min")
        add(["d", "day", "days"], .time, "d", 86400, partner: "h")
        add(["wk", "week", "weeks"], .time, "wk", 604800, partner: "d")
        return all
    }

    /// `20c`, `20 c in f`, `3 miles to km`, `180 lb in kg`.
    ///
    /// Returns nil for anything it does not fully understand, which is most of
    /// what gets typed at a launcher.
    public static func convert(_ input: String) -> Result? {
        var text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { return nil }
        text = text.replacingOccurrences(of: "°", with: "")

        // A trailing "in <unit>" or "to <unit>" names the target. "in" is also a
        // unit, so the preposition is only taken when a unit follows it.
        var target: Unit?
        for word in [" in ", " to ", " into ", ">"] {
            guard let range = text.range(of: word, options: .backwards) else { continue }
            let tail = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let unit = lookup(tail) else { continue }
            target = unit
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            break
        }

        guard let (amount, sourceName) = split(text), let source = lookup(sourceName)
        else { return nil }

        let resolved = target ?? source.partner.flatMap(lookup)
        guard let to = resolved, to.kind == source.kind else { return nil }
        // "3km in km" is not worth a row in the list.
        guard to.symbol != source.symbol else { return nil }

        let converted = source.kind == .temperature
            ? temperature(amount, from: source.symbol, to: to.symbol)
            : amount * source.ratio / to.ratio
        guard converted.isFinite else { return nil }

        let out = "\(format(converted)) \(to.symbol)"
        return Result(value: out, line: "\(format(amount)) \(source.symbol)  =  \(out)")
    }

    static func lookup(_ name: String) -> Unit? {
        table[name.replacingOccurrences(of: " ", with: "")]
    }

    /// Pull the leading number off, leaving the unit. Accepts `20c` and `20 c`.
    static func split(_ text: String) -> (Double, String)? {
        var digits = ""
        var rest = ""
        var seenUnit = false
        for character in text {
            if !seenUnit, character.isNumber || character == "." || character == "-"
                || (character == "," && !digits.isEmpty) {
                if character != "," { digits.append(character) }
            } else if character == " " && !seenUnit && digits.isEmpty {
                continue
            } else {
                seenUnit = true
                rest.append(character)
            }
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, !name.isEmpty, let amount = Double(digits) else { return nil }
        return (amount, name)
    }

    /// Temperature is the one category that is not a ratio. Absolute zero is in a
    /// different place on each scale, so an offset has to be applied both ways.
    static func temperature(_ amount: Double, from: String, to: String) -> Double {
        let celsius: Double
        switch from {
        case "°F": celsius = (amount - 32) * 5 / 9
        case "K": celsius = amount - 273.15
        default: celsius = amount
        }
        switch to {
        case "°F": return celsius * 9 / 5 + 32
        case "K": return celsius + 273.15
        default: return celsius
        }
    }

    /// Grouped, because the rest of the app groups. Currency printed 15,706 and
    /// a unit conversion printed 1609.34 on the same screen, which reads as two
    /// different programs.
    static func format(_ value: Double) -> String {
        // Past a trillion or under a ten thousandth, exponent form is shorter
        // and a separator helps nobody.
        if abs(value) >= 1e12 || (abs(value) < 1e-4 && value != 0) {
            return String(format: "%g", value)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = abs(value.rounded() - value) < 1e-9 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%g", value)
    }
}
