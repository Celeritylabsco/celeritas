import Foundation

/// Turns a natural date phrase into numbers.
///
/// AppleScript date literals are locale dependent: `date "August 5, 2026"` is a
/// syntax error on a machine formatting dates as `5 August 2026`. Rather than
/// guess the locale, phrases are parsed here and injected as plain numbers,
/// which every locale agrees on.
public struct DatePhrase: Sendable, Equatable {
    public let date: Date

    public var components: [(String, Int)] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [("y", c.year ?? 0), ("mo", c.month ?? 0), ("d", c.day ?? 0),
                ("h", c.hour ?? 0), ("mi", c.minute ?? 0)]
    }

    public var iso: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday",
                           "saturday", "sunday"]
    static let months = ["january", "february", "march", "april", "may", "june", "july",
                         "august", "september", "october", "november", "december"]

    /// Handles what people type: "tomorrow at 3", "friday", "next tuesday 09:30",
    /// "March 4", "2026-03-04". Unrecognised falls back to today, a missing time
    /// to 9am, both of which are better than refusing.
    public static func parse(_ text: String, now: Date = Date()) -> DatePhrase {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let base = calendar.date(bySetting: .second, value: 0, of: now) ?? now

        var hour: Int?
        var minute = 0
        if let m = match(t, #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#) {
            hour = (Int(m[1]) ?? 0) % 12
            minute = Int(m[2]) ?? 0
            if m[3] == "pm" { hour! += 12 }
        } else if let m = match(t, #"\b(\d{1,2}):(\d{2})\b"#) {
            hour = Int(m[1]); minute = Int(m[2]) ?? 0
        }

        var day: Date?
        if t.contains("tomorrow") {
            day = calendar.date(byAdding: .day, value: 1, to: base)
        } else if t.contains("yesterday") {
            day = calendar.date(byAdding: .day, value: -1, to: base)
        } else if t.contains("today") || t.contains("tonight") {
            day = base
        } else {
            for (index, name) in weekdays.enumerated() where t.contains(name) {
                // Calendar weekday is 1=Sunday; our list is 0=Monday.
                let target = (index + 2) % 7 + 1
                let current = calendar.component(.weekday, from: base)
                var ahead = (target - current + 7) % 7
                if ahead == 0 || t.contains("next") { ahead = ahead == 0 ? 7 : ahead }
                day = calendar.date(byAdding: .day, value: ahead, to: base)
                break
            }
        }

        if day == nil, let m = match(t, #"([a-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})?"#),
           let monthIndex = months.firstIndex(of: m[1]) {
            var c = calendar.dateComponents([.year], from: base)
            c.year = Int(m[3]) ?? c.year
            c.month = monthIndex + 1
            c.day = Int(m[2]) ?? 1
            day = calendar.date(from: c)
        }
        if day == nil, let m = match(t, #"(\d{4})-(\d{2})-(\d{2})"#) {
            var c = DateComponents()
            c.year = Int(m[1]); c.month = Int(m[2]); c.day = Int(m[3])
            day = calendar.date(from: c)
        }

        let resolved = day ?? base
        let final = calendar.date(bySettingHour: hour ?? 9, minute: hour == nil ? 0 : minute,
                                  second: 0, of: resolved) ?? resolved
        return DatePhrase(date: final)
    }

    /// The whole match at index 0 and each capture group after it. A group that
    /// did not participate comes back empty rather than nil, so call sites read
    /// as arithmetic instead of unwrapping.
    static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
    }
}
