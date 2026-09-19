import Foundation

/// Emoji by name, answered on the machine.
///
/// The index is generated from Unicode's own `emoji-test.txt` by
/// `Scripts/make-emoji.py`, so it is the authoritative list and can be rebuilt
/// whenever Unicode ships a new set. Nobody types emoji into Swift by hand.
///
/// Loaded once, on the first search that could be one, rather than at launch.
/// Four hundred kilobytes of JSON is not worth decoding for someone who only
/// ever opens apps.
public actor Emoji {
    public static let shared = Emoji()

    public struct Match: Sendable, Equatable, Identifiable {
        /// The emoji itself.
        public let character: String
        /// "grinning face"
        public let name: String
        public var id: String { character }
    }

    private struct Row: Codable {
        let e: String
        let n: String
        let k: [String]
    }

    private var rows: [Row] = []
    private var loaded = false

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Row].self, from: data)
        else { return }
        rows = decoded
    }

    /// `fire`, `rocket`, `thumbs up`, `:fire:`, `emoji heart`.
    ///
    /// A whole word has to match, or a word has to start with what was typed.
    /// Matching anywhere inside a word sounds more helpful and is not: "at"
    /// appears in "cat", "goat", "boat" and two hundred others, so every short
    /// query would return a wall.
    public func search(_ input: String, limit: Int = 8) -> [Match] {
        var text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Whether the person said they wanted emoji, which decides how loose
        // the matching is allowed to be.
        var asked = false
        // :fire: is how people write it everywhere else, so accept it here.
        if text.hasPrefix(":"), text.hasSuffix(":"), text.count > 2 {
            text = String(text.dropFirst().dropLast())
            asked = true
        }
        for opener in ["emoji for ", "emoji ", "emoji:"] where text.hasPrefix(opener) {
            text = String(text.dropFirst(opener.count))
            asked = true
            break
        }
        text = text.trimmingCharacters(in: .whitespaces)
        // One letter matches most of the set. Two is the shortest thing that
        // means something, and "ok" and "+1" are both two.
        guard text.count >= 2, text.count <= 32 else { return [] }

        load()
        guard !rows.isEmpty else { return [] }

        let terms = text.split(separator: " ").map(String.init)
        var scored: [(Int, Int, Int)] = []

        for (index, row) in rows.enumerated() {
            // Every word typed has to hit, so "red heart" narrows instead of
            // returning everything red plus everything with a heart.
            var allExact = true
            var allStart = true
            for term in terms {
                if !row.k.contains(term) {
                    allExact = false
                    if !row.k.contains(where: { $0.hasPrefix(term) }) {
                        allStart = false
                        break
                    }
                }
            }
            // Unasked, only a whole word counts. Otherwise "safari", "notes"
            // and half of what anyone types would drag an emoji row along.
            guard allExact || (allStart && asked) else { continue }

            // Rank, or "fire" answers with a fire engine. Unicode order is
            // codepoint order and has nothing to do with what people mean.
            let rank: Int
            if row.n == text { rank = 0 }                       // "fire"
            else if row.n.hasPrefix(text + " ") { rank = 1 }     // "fire engine"
            else if allExact { rank = 2 }                       // "heart on fire"
            else { rank = 3 }                                   // only a prefix hit
            scored.append((rank, row.n.count, index))
        }

        // Then the shorter name, because the plain thing is always named more
        // simply than its variants, and finally Unicode order to stay stable.
        return scored.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
            .prefix(limit)
            .map { Match(character: rows[$0.2].e, name: rows[$0.2].n) }
    }
}
