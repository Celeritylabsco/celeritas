import Foundation

/// A model we have actually measured, with the score beside it.
///
/// Nothing reaches this list without a number. A picker that recommends an
/// untested model would be the same overclaiming the rest of the project avoids.
public struct ScoredModel: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let score: String
    public let costPerRun: Double
    /// How many tasks that cost covers.
    ///
    /// Not the same as the suite the score comes from. The score is held out,
    /// 22 tasks; the cost is carried over from the longer development run
    /// because more tasks gives a steadier figure. Dividing the one by the
    /// other would overstate a question by about two and a half times.
    public let costTasks: Int?
    /// What it scored on the split it was tuned against, for contrast only.
    public let tunedScore: String?
    public let medianSeconds: Double?
    public let local: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case score
        case local
        case costPerRun = "cost_per_run"
        case costTasks = "cost_tasks"
        case tunedScore = "tuned_score"
        case medianSeconds = "median_seconds"
    }

    /// "52/55" as a percentage, for sorting and for display.
    public var accuracy: Double {
        let parts = score.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 0 }
        return parts[0] / parts[1]
    }

    /// What one question costs, which is what a person actually pays.
    ///
    /// `costPerRun` is the whole suite, every task added up. The onboarding
    /// printed it next to the words "a question" and overstated the price by the
    /// number of tasks, which made Celeritas look 55 times dearer than it is.
    public func perQuestion(over tasks: Int) -> Double {
        // Its own cost basis when it has one, because that is the run the money
        // was actually spent on.
        let over = costTasks ?? tasks
        return over > 0 ? costPerRun / Double(over) : costPerRun
    }

    /// The short name, without the vendor prefix.
    public var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    public var vendor: String {
        id.split(separator: "/").first.map(String.init) ?? ""
    }
}

public struct Shortlist: Codable, Sendable {
    public let decided: String
    public let basis: String
    /// How many tasks one run covers, so nothing has to read "55" out of `basis`.
    public let tasks: Int
    public let caveats: [String]
    public let models: [ScoredModel]

    public static let current: Shortlist = {
        guard let url = Bundle.module.url(forResource: "shortlist", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Shortlist.self, from: data)
        else { fatalError("shortlist.json is missing from the bundle") }
        return value
    }()

    /// Cheapest first, which is the order someone choosing actually wants.
    public var byCost: [ScoredModel] { models.sorted { $0.costPerRun < $1.costPerRun } }

    /// Highest scoring, ties broken by cost. What to pick for someone who has not
    /// chosen, so the default is a measured one rather than the first line of a file.
    /// Only the ones a gateway can serve. The shortlist carries the local
    /// models too, because they earned their place on the held-out split, and
    /// offering one of those under "paste your key" is nonsense.
    public var throughGateway: [ScoredModel] {
        byScore.filter { $0.local != true }
    }

    public var byScore: [ScoredModel] {
        models.sorted { ($0.accuracy, -$0.costPerRun) > ($1.accuracy, -$1.costPerRun) }
    }

    /// What a fresh install points at. Must be one a gateway can serve.
    public var best: String { throughGateway.first?.id ?? "z-ai/glm-5.3-flash" }

    /// What one question costs on a given model, at this suite's size.
    public func perQuestion(_ model: ScoredModel) -> Double { model.perQuestion(over: tasks) }
}

/// What the local model scored on the same suite, so the settings screen can say
/// plainly what choosing local costs you.
public enum LocalBaseline {
    public static let model = "LFM2.5-2.6B"
    public static let score = "39/55"
    public static let accuracy = 39.0 / 55.0
}

/// What Apple Intelligence scored on the same 55 tasks.
///
/// nil, and honestly so. Scoring it against the suite needs an OpenAI-shaped
/// endpoint, and the suite runs the tools itself against a simulated Mac, so the
/// adapter has to answer one turn at a time. Apple's API cannot be told to carry
/// on after a tool result without being given a prompt, and any prompt reads as a
/// fresh ambiguous request, so the model calls intent_unclear on every second
/// turn. First-turn tool choice was right on every case tried, at 2.2 to 2.6
/// seconds. That is not the same metric as the other models and is not reported
/// as though it were.
///
/// A picker showing an invented number would be exactly the overclaiming this
/// project exists to avoid, so the onboarding prints "not measured yet".
public enum AppleBaseline {
    public static let model = "Apple Intelligence"
    public static let score: String? = nil
    public static var accuracy: Double? {
        guard let score else { return nil }
        let parts = score.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}

/// Money at the size these answers cost. Four decimal places turned two
/// hundredths of a cent into "$0.0000", which reads as free and undersells the
/// one thing the receipt exists to show.
public func priceText(_ cost: Double) -> String {
    if cost == 0 { return "$0" }
    if cost >= 0.01 { return String(format: "$%.2f", cost) }
    if cost >= 0.0001 { return String(format: "$%.4f", cost) }
    return String(format: "$%.6f", cost)
}
