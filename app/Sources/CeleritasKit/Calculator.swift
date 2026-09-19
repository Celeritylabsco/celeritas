import Foundation

/// Arithmetic, answered here.
///
/// A launcher that sends `5+5` to a language model is doing something silly: it
/// costs a round trip, it costs money on a metered key, and it can be wrong.
///
/// Hand written rather than `NSExpression`, which raises an Objective-C
/// exception on malformed input that Swift's `try?` cannot catch. Typing `5 *`
/// abort-trapped the whole app. Nothing a person types should ever reach
/// `NSExpression`.
public enum Calculator {
    /// Openers people put in front of a sum. "what is 2 + 2" was going to the
    /// model, taking three seconds and coming back as off topic, because the
    /// parser only understood a bare expression.
    static let openers = ["what is", "whats", "what's", "how much is", "how many is",
                          "calculate", "compute", "work out", "solve", "eval"]

    public static func evaluate(_ input: String) -> String? {
        var parser = Parser(stripped(input))
        guard let value = parser.parse() else { return nil }
        guard value.isFinite else { return nil }
        if abs(value.rounded() - value) < 1e-9 && abs(value) < 1e15 {
            return String(Int(value.rounded()))
        }
        return String(format: "%g", value)
    }

    /// Take off the question wrapping, leaving the sum. Nothing here changes the
    /// arithmetic, so a phrase that is not a sum still returns nil.
    static func stripped(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix("?") || text.hasSuffix("=") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        for opener in openers where text.hasPrefix(opener + " ") {
            text = String(text.dropFirst(opener.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return text
    }

    /// Recursive descent over the four operations, powers and brackets. Returns
    /// nil for anything it does not fully understand, which is most of what
    /// somebody types at a launcher.
    struct Parser {
        let characters: [Character]
        var position = 0
        /// Set when an operator had nothing after it, so `5 *` fails rather than
        /// quietly evaluating to 5.
        var sawOperator = false

        init(_ text: String) {
            characters = Array(text.replacingOccurrences(of: " ", with: ""))
        }

        mutating func parse() -> Double? {
            guard !characters.isEmpty else { return nil }
            guard let value = expression() else { return nil }
            // Trailing rubbish means we did not understand the whole thing.
            guard position == characters.count, sawOperator else { return nil }
            return value
        }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                position += 1
                sawOperator = true
                guard let right = term() else { return nil }
                left = op == "+" ? left + right : left - right
            }
            return left
        }

        mutating func term() -> Double? {
            guard var left = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                position += 1
                sawOperator = true
                guard let right = power() else { return nil }
                switch op {
                case "*": left *= right
                case "/":
                    guard right != 0 else { return nil }
                    left /= right
                default:
                    guard right != 0 else { return nil }
                    left = left.truncatingRemainder(dividingBy: right)
                }
            }
            return left
        }

        /// Right associative, so 2^3^2 is 2^(3^2).
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                position += 1
                sawOperator = true
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek() == "-" {
                position += 1
                guard let value = unary() else { return nil }
                return -value
            }
            return primary()
        }

        mutating func primary() -> Double? {
            guard let character = peek() else { return nil }
            if character == "(" {
                position += 1
                guard let value = expression(), peek() == ")" else { return nil }
                position += 1
                return value
            }
            return number()
        }

        mutating func number() -> Double? {
            var digits = ""
            while let character = peek(), character.isNumber || character == "." {
                digits.append(character)
                position += 1
            }
            return digits.isEmpty ? nil : Double(digits)
        }

        func peek() -> Character? {
            position < characters.count ? characters[position] : nil
        }
    }
}
