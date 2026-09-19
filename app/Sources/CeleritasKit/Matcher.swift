import Foundation

public struct Match: Sendable, Equatable {
    public let tool: String
    public let arguments: [String: String]
    /// What to show in the list before it runs.
    public let label: String
}

/// The fast path.
///
/// Most of what anyone types at a launcher is a name, not a sentence. "battery"
/// is a lookup and should never cost a model round trip. Only sentences the index
/// cannot answer are worth sending anywhere.
///
/// Matching is deliberately conservative: a wrong instant action is worse than a
/// slow correct one, so anything ambiguous falls through to the model.
public enum Matcher {
    /// Hand-written triggers. Derived keywords were tried first and matched far
    /// too eagerly, because tool descriptions share most of their words.
    static let triggers: [String: [String]] = [
        "battery_status":   ["battery", "charge", "power", "batt"],
        "disk_free":        ["disk", "space", "storage", "free space", "disk space"],
        "memory_pressure":  ["memory", "ram", "swap", "pressure"],
        "top_processes":    ["cpu", "processes", "activity", "top"],
        "wifi_status":      ["wifi", "wi-fi", "network", "ssid"],
        "current_datetime": ["date", "time", "today", "now"],
        "lock_screen":      ["lock", "lock screen"],
        "unread_count":     ["unread", "inbox count"],
        "list_recent_mail": ["mail", "email", "recent mail", "inbox"],
        "list_reminders":   ["reminders", "todo", "todos"],
        "next_event":       ["next event", "next meeting", "agenda"],
        "recent_files":     ["recent", "recent files"],
        "large_files":      ["large files", "biggest files", "big files"],
        "empty_trash":      ["empty trash", "trash"],
        "list_events":      ["calendar", "events", "schedule"],
    ]

    /// Words that carry no intent of their own. A query made of a trigger plus
    /// only these is still a lookup, and a query with anything else in it is a
    /// sentence about something else that happens to mention the word.
    ///
    /// This exists because "am i free today" ended in a trigger for the clock and
    /// was answered with the date. The question was about the calendar. A trailing
    /// "today" almost never asks what day it is.
    static let filler: Set<String> = [
        "what", "whats", "what's", "whats", "is", "are", "the", "my", "mine",
        "show", "me", "get", "tell", "give", "current", "currently",
        "how", "much", "many", "a", "an", "of", "s", "right",
        // Qualifiers that name part of an answer rather than a different question.
        "percentage", "percent", "level", "status", "state", "usage",
        "left", "remaining", "used", "info", "check",
    ]

    /// `volume 20`, `volume to 20`, `set volume 20`.
    static let volumePattern = #"^(?:set\s+)?(?:the\s+)?volume\s*(?:to\s*)?(\d{1,3})$"#

    public static func match(_ query: String) -> Match? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count >= 2 else { return nil }

        if let m = DatePhrase.match(q, volumePattern), let level = Int(m[1]), level <= 100 {
            return Match(tool: "set_volume", arguments: ["level": String(level)],
                         label: "Set volume to \(level)")
        }
        if q == "dark" || q == "dark mode" || q == "darkmode" {
            return Match(tool: "set_dark_mode", arguments: ["state": "on"], label: "Dark mode on")
        }
        if q == "light" || q == "light mode" {
            return Match(tool: "set_dark_mode", arguments: ["state": "off"], label: "Dark mode off")
        }
        if q == "mute" {
            return Match(tool: "mute_audio", arguments: ["state": "on"], label: "Mute")
        }
        if q == "unmute" {
            return Match(tool: "mute_audio", arguments: ["state": "off"], label: "Unmute")
        }

        let words = q.split(separator: " ").map(String.init)

        // An exact trigger wins outright.
        for (tool, keys) in triggers where keys.contains(q) { return made(tool) }

        // A query that opens with a trigger wins too, as long as it is short.
        // "battery percentage" is a lookup; "the battery died, remind me to buy
        // one" is a sentence, and the word limit is what tells them apart.
        if words.count <= 4 {
            var leadHits: [String] = []
            for (tool, keys) in triggers {
                let leads = keys.contains { key in covers(q, key) }
                if leads { leadHits.append(tool) }
            }
            // Longest trigger wins, so "disk space" beats "disk" without either
            // being ambiguous.
            if leadHits.count == 1 { return made(leadHits[0]) }
            if leadHits.count > 1 {
                let best = leadHits.max { a, b in
                    longestTrigger(a, in: q) < longestTrigger(b, in: q)
                }
                if let best, longestTrigger(best, in: q) > 0 { return made(best) }
            }
        }

        // A prefix only wins when exactly one tool claims it, so "re" never
        // silently picks between reminders and recent files.
        var prefixHits: [String] = []
        for (tool, keys) in triggers where keys.contains(where: { $0.hasPrefix(q) }) {
            prefixHits.append(tool)
        }
        if prefixHits.count == 1 { return made(prefixHits[0]) }
        return nil
    }

    /// Whether this trigger accounts for the whole query.
    ///
    /// The trigger has to be present as whole words, and everything left over has
    /// to be filler. "battery percentage" is a lookup. "am i free today" is not,
    /// even though it ends in a trigger, because "am i free" is not filler.
    static func covers(_ query: String, _ key: String) -> Bool {
        if query == key { return true }
        guard query.hasPrefix(key + " ") || query.hasSuffix(" " + key)
                || query.contains(" " + key + " ") else { return false }
        let rest = query
            .replacingOccurrences(of: key, with: " ")
            .split(separator: " ")
            .map(String.init)
        return rest.allSatisfy(filler.contains)
    }

    /// How many characters of the query a tool's best matching trigger covers.
    static func longestTrigger(_ tool: String, in query: String) -> Int {
        (triggers[tool] ?? [])
            .filter { covers(query, $0) }
            .map(\.count)
            .max() ?? 0
    }

    /// What a person sees before pressing return. The catalogue's description is
    /// written for a model to choose from and reads like schema documentation, so
    /// it is the wrong text to put in front of someone typing two letters.
    static let labels: [String: String] = [
        "battery_status":   "Battery level",
        "disk_free":        "Free disk space",
        "memory_pressure":  "Memory and swap",
        "top_processes":    "What is using the CPU",
        "wifi_status":      "Current wifi network",
        "current_datetime": "Date and time",
        "lock_screen":      "Lock the screen",
        "unread_count":     "Unread mail count",
        "list_recent_mail": "Recent mail",
        "list_reminders":   "Outstanding reminders",
        "next_event":       "Next event",
        "recent_files":     "Recently changed files",
        "large_files":      "Largest files",
        "empty_trash":      "Empty the Trash",
        "list_events":      "Today's events",
        "set_dark_mode":    "Dark mode",
        "mute_audio":       "Mute",
        "set_volume":       "Set volume",
    ]

    static func made(_ tool: String) -> Match? {
        guard let definition = ToolCatalog.tool(named: tool) else { return nil }
        var arguments: [String: String] = [:]
        // Every remaining parameter is a limit or a day, and both have defaults
        // the executor supplies.
        for (key, type) in definition.params where type == "integer" {
            arguments[key] = "10"
        }
        for (key, type) in definition.params where type == "date" {
            arguments[key] = "today"
        }
        return Match(tool: tool, arguments: arguments,
                     label: labels[tool] ?? definition.description)
    }
}
