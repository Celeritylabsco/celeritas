import Foundation

public enum ResultKind: String, Sendable {
    case app, action, calculator, ask, settings, conversion
}

public struct Result: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ResultKind
    public let title: String
    /// What kind of thing this is, shown on the right of the row.
    public let tag: String
    /// A file path for an app, so the view can ask the system for its icon.
    public let iconPath: String?
    /// Set for an action: the tool to run and what to pass it.
    public let tool: String?
    public let arguments: [String: String]

    public init(id: String, kind: ResultKind, title: String, tag: String,
                iconPath: String? = nil, tool: String? = nil,
                arguments: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.tag = tag
        self.iconPath = iconPath
        self.tool = tool
        self.arguments = arguments
    }
}

public struct ResultSection: Sendable, Identifiable {
    public let title: String
    public let results: [Result]
    public var id: String { title }

    public init(title: String, results: [Result]) {
        self.title = title
        self.results = results
    }
}

/// Everything the launcher can offer for one query, in the order a person wants
/// it. Arithmetic first because it is certain, then apps because that is what a
/// launcher is mostly used for, then actions, and the model last as a deliberate
/// choice rather than a silent fallback.
public enum Results {
    public static func build(for query: String, modelName: String) async -> [ResultSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var sections: [ResultSection] = []

        if let answer = Calculator.evaluate(q) {
            sections.append(ResultSection(title: "Calculator", results: [
                Result(id: "calc", kind: .calculator, title: answer, tag: "copy")
            ]))
        }

        // Currency before units, because a currency code is a narrower match:
        // both sides have to be known codes, so nothing else can claim it.
        if let money = Currency.convert(q, using: Currency.table()) {
            sections.append(ResultSection(title: "Currency", results: [
                Result(id: "currency", kind: .conversion, title: money.value,
                       tag: money.asOf)
            ]))
        }

        // Markets after currency, because a currency conversion needs two known
        // codes and is the narrower claim on a short query. Reuses .conversion:
        // a price row copies and looks the same, and a new kind would mean five
        // switches changed for no difference in behaviour.
        // Before the quote lookup, and before the model ever sees it. A model
        // asked "1 eth to sol" answers from prices it half remembers.
        if let swap = await Markets.shared.convert(q) {
            sections.append(ResultSection(title: "Markets", results: [
                Result(id: "swap", kind: .conversion, title: swap.line, tag: swap.asOf)
            ]))
        }

        // Tokens come from whatever the lookup has already found. The fetch
        // itself runs behind the field, and the list is rebuilt when it lands,
        // so nothing here waits on the network.
        var found = await Tokens.shared.cached(Tokens.wanted(in: q) ?? q)
        // A watched token answers to its bare name as well, with nothing on
        // the wire, which is the point of adding it.
        for token in await Tokens.shared.watchedMatch(q) where !found.contains(token) {
            found.insert(token, at: 0)
        }
        if !found.isEmpty {
            sections.append(ResultSection(title: "Tokens", results: found.map { token in
                let move = token.change24h.map { String(format: "  %@%.2f%%", $0 >= 0 ? "+" : "", $0) } ?? ""
                return Result(
                    id: "token:" + token.id, kind: .conversion,
                    title: "\(token.symbol)  \(Tokens.money(token.price))\(move)",
                    // Liquidity, always. A copy of a token made to be mistaken
                    // for the real one cannot fake a deep pool, so this is the
                    // number that tells them apart at a glance.
                    tag: "\(token.name) on \(token.chain), \(Tokens.short(token.liquidity)) liquidity",
                    tool: nil,
                    arguments: ["copy": Tokens.money(token.price),
                                "token": token.address])
            }))
        }

        let quotes = await Markets.shared.quotes(for: q)
        if !quotes.isEmpty {
            sections.append(ResultSection(title: "Markets", results:
                quotes.enumerated().map { index, quote in
                    Result(id: "market:\(index)", kind: .conversion,
                           title: quote.line, tag: quote.asOf)
                }))
        }

        // Right after arithmetic, for the same reason: it is certain, instant and
        // costs nothing, so it should never reach the model.
        if let converted = Units.convert(q) {
            sections.append(ResultSection(title: "Conversion", results: [
                Result(id: "unit", kind: .conversion, title: converted.value,
                       tag: converted.line)
            ]))
        }

        // Emoji before apps, because a whole word match here is a precise hit
        // and an app search is fuzzy by design.
        let emoji = await Emoji.shared.search(q)
        if !emoji.isEmpty {
            sections.append(ResultSection(title: "Emoji", results: emoji.map {
                // `copy` says what lands on the clipboard, so the row can show
                // the name beside the character and still copy the character.
                Result(id: "emoji:" + $0.character, kind: .conversion,
                       title: "\($0.character)   \($0.name)", tag: "copy",
                       arguments: ["copy": $0.character])
            }))
        }

        let apps = await AppIndex.shared.search(q, limit: 6)
        if !apps.isEmpty {
            sections.append(ResultSection(title: "Applications", results: apps.map {
                Result(id: "app:" + $0.path, kind: .app, title: $0.name,
                       tag: "Application", iconPath: $0.path)
            }))
        }

        // Celeritas has no Dock icon and no window of its own, so the menu bar was
        // the only way in. Typing for it is how people look for settings.
        if Self.settingsWords.contains(where: { $0.hasPrefix(q.lowercased()) }) {
            sections.append(ResultSection(title: "Celeritas", results: [
                Result(id: "settings", kind: .settings,
                       title: "Settings", tag: "command \u{2318},")
            ]))
        }

        if let match = Matcher.match(q) {
            let tag = ToolCatalog.tool(named: match.tool)?.app ?? "Mac"
            sections.append(ResultSection(title: "Actions", results: [
                Result(id: "action:" + match.tool, kind: .action, title: match.label,
                       tag: tag, tool: match.tool, arguments: match.arguments)
            ]))
        }

        // Always offered, never automatic. Sending a request to a model is a
        // decision, and the row says which model will get it.
        sections.append(ResultSection(title: "Ask", results: [
            Result(id: "ask", kind: .ask, title: q, tag: modelName)
        ]))
        return sections
    }

    static let settingsWords = ["settings", "preferences", "prefs", "celeritas"]

    public static func flatten(_ sections: [ResultSection]) -> [Result] {
        sections.flatMap(\.results)
    }
}
