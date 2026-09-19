import CeleritasKit
import Foundation

// Which path answers a query, and whether the answer is right.
//
// The tool-use suite measures a model. This measures the launcher. Almost
// everything typed into Celeritas never reaches a model, and our own code picks
// which of about ten paths handles it. That choice is invisible until it is
// wrong, and it has been wrong twice in one day: "am i free today" was taken by
// the clock because the word "today" appeared at the end, and "1 eth to sol"
// was handed to a model that answered 66 when the truth was 23.6.
//
//     swift run RoutingBench --spec ../bench/routing.json --out ../bench/results
//
// Two scores from one pass. Routing is whether the right section appeared and
// the wrong ones did not. Correctness is whether the answer inside it is right,
// checked only on the cases where there is a single right answer.

struct Spec: Decodable {
    struct Case: Decodable {
        let query: String
        let section: String?
        let forbid: [String]?
        let contains: String?
        let note: String?
    }
    let cases: [Case]
}

struct Row: Encodable {
    let query: String
    let expected: String?
    let forbid: [String]
    let got: [String]
    let routed: Bool
    let answer: String?
    let wanted: String?
    let correct: Bool?
    let note: String?
    let seconds: Double
}

func value(of argument: String, in arguments: [String], or fallback: String) -> String {
    guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count
    else { return fallback }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let specPath = value(of: "--spec", in: arguments, or: "bench/routing.json")
let outPath = value(of: "--out", in: arguments, or: "bench/results")

guard let data = FileManager.default.contents(atPath: specPath),
      let spec = try? JSONDecoder().decode(Spec.self, from: data)
else {
    print("could not read \(specPath)")
    exit(1)
}

// The tables the launcher answers from. Missing ones are reported rather than
// silently scoring zero, because "the cache was empty" and "the router is
// broken" look identical in the results otherwise.
let haveRates = Currency.table() != nil
let haveShares = LabAPI.cached("markets", as: Markets.Shares.self) != nil
let haveCoins = LabAPI.cached("crypto", as: Markets.Coins.self) != nil
print("tables: rates \(haveRates ? "yes" : "NO"), shares \(haveShares ? "yes" : "NO"), "
      + "coins \(haveCoins ? "yes" : "NO")")
if !(haveRates && haveShares && haveCoins) {
    print("  a missing table fails every case that needs it, which is not a routing fault")
}
print("")

var rows: [Row] = []
for item in spec.cases {
    let started = Date()
    let sections = await Results.build(for: item.query, modelName: "bench")
    let seconds = Date().timeIntervalSince(started)
    let titles = sections.map(\.title)

    let appeared = item.section.map(titles.contains) ?? true
    let forbidden = item.forbid ?? []
    let intruded = forbidden.filter(titles.contains)
    let routed = appeared && intruded.isEmpty

    // The text of the row in the expected section, for the correctness check.
    var answer: String?
    if let wanted = item.section,
       let section = sections.first(where: { $0.title == wanted }) {
        answer = section.results.map { "\($0.title)  \($0.tag)" }.joined(separator: " | ")
    }
    let correct: Bool? = item.contains.map { needle in
        (answer ?? "").localizedCaseInsensitiveContains(needle)
    }

    rows.append(Row(query: item.query, expected: item.section, forbid: forbidden,
                    got: titles, routed: routed, answer: answer,
                    wanted: item.contains, correct: correct,
                    note: item.note, seconds: seconds))

    let mark = routed ? (correct == false ? "VALUE" : "OK   ") : "ROUTE"
    var line = "\(mark) \(item.query.isEmpty ? "(empty)" : item.query)"
    if !routed {
        if !appeared { line += "   wanted \(item.section ?? "?"), got \(titles)" }
        if !intruded.isEmpty { line += "   must not have shown \(intruded)" }
    } else if correct == false {
        line += "   wanted \"\(item.wantedText)\", got \"\(answer ?? "")\""
    }
    print(line)
}

extension Spec.Case {
    var wantedText: String { contains ?? "" }
}

let routedCount = rows.filter(\.routed).count
let checked = rows.filter { $0.correct != nil }
let correctCount = checked.filter { $0.correct == true }.count

print("")
print("  routing      \(routedCount)/\(rows.count)  (\(String(format: "%.3f", Double(routedCount) / Double(rows.count))))")
print("  correctness  \(correctCount)/\(checked.count)  (\(String(format: "%.3f", Double(correctCount) / Double(max(checked.count, 1)))))")

struct Record: Encodable {
    let suite = "routing"
    let started_utc: String
    let cases: Int
    let routed: Int
    let routing_accuracy: Double
    let value_checked: Int
    let value_correct: Int
    let value_accuracy: Double
    let tables: [String: Bool]
    let rows: [Row]
}

let stamp = ISO8601DateFormatter().string(from: Date())
let record = Record(
    started_utc: stamp, cases: rows.count, routed: routedCount,
    routing_accuracy: Double(routedCount) / Double(rows.count),
    value_checked: checked.count, value_correct: correctCount,
    value_accuracy: Double(correctCount) / Double(max(checked.count, 1)),
    tables: ["rates": haveRates, "markets": haveShares, "crypto": haveCoins],
    rows: rows)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let file = outPath + "/" + stamp.replacingOccurrences(of: ":", with: "-") + "_routing.json"
try? FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
try? encoder.encode(record).write(to: URL(fileURLWithPath: file))
print("  written    \(file)")
exit(routedCount == rows.count && correctCount == checked.count ? 0 : 1)
