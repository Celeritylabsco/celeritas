import Foundation

public struct InstalledApp: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public var id: String { path }
}

/// Every app on the machine, found once and kept.
///
/// Built from the filesystem rather than Spotlight: `mdfind` misses apps in
/// folders Spotlight has not indexed, and a launcher that cannot find an app the
/// person can see in Finder is broken in the most obvious possible way.
public actor AppIndex {
    public static let shared = AppIndex()

    private var apps: [InstalledApp] = []
    private var built = false

    static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        // Finder lives here rather than in any Applications folder, and a
        // launcher that cannot find Finder looks broken immediately.
        "/System/Library/CoreServices",
        "/System/Library/CoreServices/Applications",
    ]

    public func all() -> [InstalledApp] {
        if !built { build() }
        return apps
    }

    public func refresh() {
        built = false
        build()
    }

    private func build() {
        var found: [String: InstalledApp] = [:]
        let fm = FileManager.default
        for root in AppIndex.roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let name = String(entry.dropLast(4))
                let path = root + "/" + entry
                // First root wins, so a user copy does not shadow the system one
                // twice in the list.
                if found[name] == nil { found[name] = InstalledApp(name: name, path: path) }
            }
        }
        apps = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        built = true
    }

    /// Ranked matches. Prefix beats word-start beats subsequence, because that is
    /// the order a person expects: typing "ma" should offer Mail before Activity
    /// Monitor.
    public func search(_ query: String, limit: Int = 8) -> [InstalledApp] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        if !built { build() }

        var scored: [(Int, InstalledApp)] = []
        for app in apps {
            let name = app.name.lowercased()
            if name == q { scored.append((0, app)) }
            else if name.hasPrefix(q) { scored.append((1, app)) }
            else if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
                scored.append((2, app))
            } else if initials(app.name).hasPrefix(q) { scored.append((3, app)) }
            else if isSubsequence(q, of: name) { scored.append((4, app)) }
        }
        return scored
            .sorted { ($0.0, $0.1.name.count) < ($1.0, $1.1.name.count) }
            .prefix(limit)
            .map(\.1)
    }

    /// "Activity Monitor" -> "am", so initials find a two word app.
    func initials(_ name: String) -> String {
        name.split(separator: " ").compactMap { $0.first }.map(String.init)
            .joined().lowercased()
    }

    func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var i = needle.startIndex
        for character in haystack where i < needle.endIndex && character == needle[i] {
            i = needle.index(after: i)
        }
        return i == needle.endIndex
    }
}
