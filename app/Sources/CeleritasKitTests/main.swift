import CeleritasKit
import Foundation

// A plain executable rather than a test target: XCTest does not ship with the
// Command Line Tools, so `swift test` would need a full Xcode.
// This runs on one thread from top to bottom, so the counter needs no isolation
// and saying so is more honest than wrapping it in a class to satisfy the rule.
nonisolated(unsafe) var failures = 0

// Top level await needs the file to be a main.swift, which it is.

func check(_ label: String, _ condition: Bool) {
    if condition { print("  ok    \(label)") } else { print("  FAIL  \(label)"); failures += 1 }
}

print("catalogue")
check("loads every tool", ToolCatalog.count == 32)
check("intent_unclear exists", ToolCatalog.tool(named: "intent_unclear") != nil)
check("four tools are destructive",
      ToolCatalog.all.values.filter(\.destructive).count == 4)
check("schema covers the catalogue", ToolCatalog.schema().count == ToolCatalog.count)

print("escaping, the security boundary")
check("double quote escaped", Executor.appleScriptSafe("say \"hi\"") == "say \\\"hi\\\"")
check("backslash escaped", Executor.appleScriptSafe("a\\b") == "a\\\\b")
check("control characters stripped", Executor.appleScriptSafe("a\u{0}b") == "ab")
check("single quote neutralised for the shell",
      Executor.shellSafe("it's") == "it'\"'\"'s")

print("refusals")
check("unknown tool", Executor.run("no_such_tool").ok == false)
check("unknown argument", Executor.run("disk_free", ["path": "/"]).ok == false)
check("destructive without confirm asks",
      Executor.run("empty_trash").needsConfirmation)

print("date phrases")
let tomorrow = DatePhrase.parse("tomorrow at 3pm")
check("tomorrow at 3pm gives 15:00", tomorrow.components.first { $0.0 == "h" }?.1 == 15)
let bare = DatePhrase.parse("friday")
check("a bare day defaults to 9am", bare.components.first { $0.0 == "h" }?.1 == 9)
check("iso format is locale independent",
      DatePhrase.parse("2026-03-04").iso.hasPrefix("2026-03-04"))

print("read-only tools against the real Mac")
let battery = Executor.run("battery_status")
check("battery_status returns something", battery.ok && !battery.output.isEmpty)
let disk = Executor.run("disk_free")
check("disk_free returns something", disk.ok && disk.output.contains("free"))

print("the instant path")
func matches(_ query: String, _ tool: String) -> Bool { Matcher.match(query)?.tool == tool }
check("battery", matches("battery", "battery_status"))
check("battery percentage", matches("battery percentage", "battery_status"))
check("disk space", matches("disk space", "disk_free"))
check("how much disk space left", matches("disk space left", "disk_free"))
check("wifi", matches("wifi", "wifi_status"))
check("volume 20 parses the number",
      Matcher.match("volume 20")?.arguments["level"] == "20")
check("set the volume to 35 parses too",
      Matcher.match("set the volume to 35")?.arguments["level"] == "35")
check("dark", matches("dark", "set_dark_mode"))
check("a sentence falls through to the model",
      Matcher.match("the battery died, remind me to buy a charger") == nil)
check("an ambiguous fragment falls through", Matcher.match("re") == nil)
check("empty query matches nothing", Matcher.match("") == nil)

print("the calculator")
check("5+5", Calculator.evaluate("5+5") == "10")
check("2 * 3.5", Calculator.evaluate("2 * 3.5") == "7")
check("10/4 is not integer division", Calculator.evaluate("10/4") == "2.5")
check("(2+3)*4", Calculator.evaluate("(2+3)*4") == "20")
check("2^10", Calculator.evaluate("2^10") == "1024")
check("a bare number is not a sum", Calculator.evaluate("42") == nil)
// "what is 5+5" used to be required to fail. It answers now, on purpose.
check("a question around a sum is a sum", Calculator.evaluate("what is 5+5") == "10")
check("words are not a sum", Calculator.evaluate("hello world") == nil)
check("divide by zero returns nothing", Calculator.evaluate("5/0") == nil)
check("empty returns nothing", Calculator.evaluate("") == nil)
check("a dangling operator does not crash", Calculator.evaluate("5 *") == nil)
check("a dangling plus", Calculator.evaluate("5 +") == nil)
check("an unclosed bracket", Calculator.evaluate("(2+3") == nil)
check("a lone operator", Calculator.evaluate("*") == nil)
check("two operators", Calculator.evaluate("5 ** 3") == nil)
check("trailing rubbish", Calculator.evaluate("5+5x") == nil)
check("negatives", Calculator.evaluate("-3 + 10") == "7")
check("precedence", Calculator.evaluate("2+3*4") == "14")
check("brackets beat precedence", Calculator.evaluate("(2+3)*4") == "20")
check("power is right associative", Calculator.evaluate("2^3^2") == "512")
check("modulo", Calculator.evaluate("10%3") == "1")
check("modulo by zero", Calculator.evaluate("10%0") == nil)

print("the app index")
let index = AppIndex.shared
let everything = await index.all()
check("finds installed apps", everything.count > 10)
check("finds Finder", everything.contains { $0.name == "Finder" })
let safari = await index.search("safa")
check("prefix search finds Safari", safari.first?.name == "Safari")
let initials = await index.search("am")
check("initials find Activity Monitor",
      initials.contains { $0.name == "Activity Monitor" })
let none = await index.search("")
check("empty query returns nothing", none.isEmpty)

// Apple Intelligence, only when asked for with `--apple`. It is a live model call,
// so it does not belong in a suite that has to run anywhere in under a second.
if CommandLine.arguments.contains("--apple") {
    print("")
    print("apple intelligence")
    if #available(macOS 26.0, *) {
        if let reason = AppleClient.unavailableReason {
            print("  SKIP  \(reason)")
        } else {
            AppleClient.prewarm()
            let agent = AppleAgent(execute: { name, args, _ in
                ToolResult.success("(ran \(name) \(args))")
            })
            for prompt in ["what is my battery",
                           "set the volume to 30",
                           "open safari",
                           "what is the airspeed velocity of a swallow"] {
                let started = Date()
                do {
                    let outcome = try await agent.run(prompt)
                    let picked = outcome.steps.map { $0.tool }.joined(separator: ",")
                    print(String(format: "  %.2fs  %-42@ -> %@", Date().timeIntervalSince(started),
                                 prompt as NSString,
                                 (picked.isEmpty ? (outcome.reply ?? "(no tool, no reply)")
                                                 : picked) as NSString))
                } catch {
                    print("  FAIL  \(prompt): \(error)")
                    failures += 1
                }
            }
        }
    } else {
        print("  SKIP  needs macOS 26")
    }
}

print("")
print("the instant path only takes what it owns")
// Sentences that merely mention a trigger word belong to the model. "am i free
// today" was answered with the clock, because it ends in "today".
for sentence in ["am i free today", "am i free tomorrow", "do i have time now",
                 "is the meeting today", "remind me to charge", "who is free now"] {
    check("falls through: \(sentence)", Matcher.match(sentence) == nil)
}
// Lookups that must stay instant. Each of these was a complaint at some point.
for (query, tool) in [("battery", "battery_status"),
                      ("battery percentage", "battery_status"),
                      ("what is my battery", "battery_status"),
                      ("disk space", "disk_free"),
                      ("how much disk space", "disk_free"),
                      ("whats the time", "current_datetime"),
                      ("today", "current_datetime"),
                      ("wifi", "wifi_status")] {
    check("instant: \(query) -> \(tool)", Matcher.match(query)?.tool == tool)
}

print("")
print("sums written as questions")
for (query, answer) in [("what is 2 + 2", "4"), ("whats 5*12", "60"),
                        ("what is 2 + 2?", "4"), ("calculate (2+3)*4", "20"),
                        ("how much is 10/4", "2.5"), ("2+2 =", "4")] {
    check("\(query) -> \(answer)", Calculator.evaluate(query) == answer)
}
// Stripping the opener must not turn a sentence into a sum.
for sentence in ["what is my battery", "what is the time", "calculate my taxes"] {
    check("still not a sum: \(sentence)", Calculator.evaluate(sentence) == nil)
}
print("")
print("prices at the size these answers cost")
check("two hundredths of a cent is not $0.0000", priceText(0.0000198) != "$0.0000")
check("small price keeps its digits", priceText(0.0000198) == "$0.000020")
check("normal price is two places", priceText(0.34) == "$0.34")
check("zero is zero", priceText(0) == "$0")

print("")
print("what a question costs")
let sl = Shortlist.current
// The score comes from the 22 held-out tasks; the cost is carried over from the
// longer development run. They are different suites on purpose, and each model
// says which one its money was spent on.
check("the scoring suite is the held-out one", sl.tasks == 22)
if let top = sl.byScore.first {
    let each = sl.perQuestion(top)
    check("a cost basis is recorded", top.costTasks != nil)
    check("per question divides by the cost's own suite, not the score's",
          abs(each - top.costPerRun / Double(top.costTasks ?? sl.tasks)) < 1e-12)
    // Dividing $0.01009 by 22 instead of 55 would price a question at
    // $0.00046 rather than $0.00018, two and a half times too much.
    check("and not by the held-out count",
          abs(each - top.costPerRun / 22.0) > 1e-9)
    // The bug this replaced: the onboarding printed the suite total beside the
    // words "a question", so $0.003182 was shown as the price of one question.
    check("per question is far below the suite total", each < top.costPerRun / 10)
    print("  note  \(top.shortName): suite $\(top.costPerRun), question $\(each)")
}

print("")
print("unit conversion, offline")
for (query, expect) in [("20c", "68 °F"), ("100f", "37.78 °C"), ("0c to k", "273.15 K"),
                        ("3 miles in km", "4.83 km"), ("180 lb in kg", "81.65 kg"),
                        ("2gb in mb", "2,000 MB"), ("1 gib in mb", "1,073.74 MB"),
                        ("1 gal in l", "3.79 l"), ("1 impgal in l", "4.55 l"),
                        ("90 mph in kph", "144.84 km/h"), ("2h in min", "120 min"),
                        ("6ft in cm", "182.88 cm"), ("5 km", "3.11 mi")] {
    let got = Units.convert(query)?.value
    check("\(query) -> \(expect)", got == expect)
    if got != expect { print("        got \(got ?? "nil")") }
}
// A gallon and a KB are chosen, never guessed. Both have a wrong answer that
// looks right, so the label has to say which one was used.
check("gallon says which one", Units.convert("1 gal in l")?.line.contains("gal (US)") == true)
check("imperial gallon is different", Units.convert("1 impgal in l")?.value
        != Units.convert("1 gal in l")?.value)
check("KB is 1000, KiB is 1024", Units.convert("1kb in b")?.value == "1,000 B"
        && Units.convert("1kib in b")?.value == "1,024 B")
// Nonsense, and things that belong to something else, fall through.
for miss in ["hello", "5 + 5", "20", "c", "3 miles in kg", "3km in km", "safari",
             "what is my battery", "100 usd in eur"] {
    check("falls through: \(miss)", Units.convert(miss) == nil)
}

print("")
print("currency, from the lab's table")
let fakeTable = Currency.Table(base: "USD", rates: [
    "JPY": .init(rate: 157.06, date: "2026-09-19"),
    "GBP": .init(rate: 0.74683, date: "2026-09-20"),
    "EUR": .init(rate: 0.86986, date: "2026-09-20"),
])
check("100 usd in jpy", Currency.convert("100 usd in jpy", using: fakeTable)?.value == "15,706 JPY")
// The doc comment promised "20 chf jpy" from the day the file was written and
// the code never did it. The routing suite found it on 19 Sep 2026.
check("a bare pair needs no joining word",
      Currency.convert("100 usd jpy", using: fakeTable)?.value == "15,706 JPY")
check("and it still needs two known codes",
      Currency.convert("100 usd banana", using: fakeTable) == nil)
// Dropping the last word off "100 usd" would leave no source currency, and
// "5 km" must still reach the unit converter.
check("a lone amount and code is not a pair",
      Currency.convert("100 usd", using: fakeTable) == nil)
check("units are still left alone",
      Currency.convert("5 km", using: fakeTable) == nil)
check("cross pair goes through the base",
      Currency.convert("100 gbp to eur", using: fakeTable)?.value == "116.47 EUR")
check("the rate's own date is shown",
      Currency.convert("100 usd in jpy", using: fakeTable)?.asOf == "rate from 19 Sep")
// Currency must not swallow a unit conversion, and units must not swallow money.
check("units are left alone", Currency.convert("3 miles in km", using: fakeTable) == nil)
check("money is left alone by units", Units.convert("100 usd in eur") == nil)
for miss in ["100 usd", "usd in eur", "hello", "5 + 5", "100 usd in usd",
             "100 xyz in eur"] {
    check("falls through: \(miss)", Currency.convert(miss, using: fakeTable) == nil)
}
// A code we know with no rate in the table says so rather than going silent.
check("unknown rate is named",
      Currency.convert("10 usd in sek", using: fakeTable)?.value == "No rate for SEK")
check("first run says what is missing",
      Currency.convert("100 usd in eur", using: nil)?.value == "Rates not downloaded yet")

print("markets")
let fakeShares = Markets.Shares(asOf: "2026-09-18", stocks: [
    "AAPL": Markets.Row(c: 336.13, p: -0.26, n: "Apple Inc."),
    "TSLA": Markets.Row(c: 364.27, p: -0.53, n: "Tesla, Inc."),
    "F":    Markets.Row(c: 12.41, p: 1.2, n: "Ford Motor Company"),
    "IT":   Markets.Row(c: 240.5, p: 0.1, n: "Gartner Inc."),
    "PENNY": Markets.Row(c: 0.0432, p: -3.1, n: nil),
])
let fakeCoins = Markets.Coins(asOf: "2026-09-19 14:07:04", coins: [
    "BTC":  Markets.Coin(c: 81288.44, p: 0.23, n: "Bitcoin",
                         h: 81723.7, l: 80859.99, t: "2026-09-19 14:07:04"),
    "PEPE": Markets.Coin(c: 3.83e-06, p: -0.78, n: "Pepe", t: "2026-09-19 14:07:06"),
    "LINK": Markets.Coin(c: 12.561, p: 1.74, n: "Chainlink", t: "2026-09-19 14:07:04"),
])
await Markets.shared.adopt(shares: fakeShares, coins: fakeCoins)

func quote(_ q: String) async -> String? { await Markets.shared.quote(for: q)?.line }
func about(_ q: String) async -> String? { await Markets.shared.quote(for: q)?.asOf }

check("a ticker on its own", await quote("aapl")?.hasPrefix("AAPL  336.13") == true)
check("case does not matter", await quote("AAPL") == (await quote("aapl")))
check("the change is signed", await quote("tsla")?.contains("-0.53%") == true)
check("a gain is signed too", await quote("f price")?.contains("+1.20%") == true)
check("a company name resolves", await quote("tesla")?.hasPrefix("TSLA") == true)
check("price words are stripped", await quote("tsla stock")?.hasPrefix("TSLA") == true)
check("leading price words too", await quote("price of aapl")?.hasPrefix("AAPL") == true)

// A share is a close on a named session, a coin is live to the minute. Saying
// which is the whole point: the same number means different things.
check("a share says it is a close", await about("aapl") == "Apple Inc., close 18 Sep")
check("a coin says it is live", await about("btc") == "Bitcoin, live 14:07")
check("a coin is priced in dollars", await quote("btc")?.contains("81,288.44 USD") == true)
check("a coin name resolves", await quote("bitcoin")?.hasPrefix("BTC") == true)
check("a renamed coin keeps its ticker", await quote("link")?.hasPrefix("LINK") == true)
check("and its familiar name", await about("chainlink") == "Chainlink, live 14:07")

// Pepe is 0.00000383. Four decimal places would print it as 0, which is the
// kind of wrong that looks like a working feature.
check("a sub cent coin keeps its digits", await quote("pepe")?.contains("0.00000383") == true)
check("small share prices too", await quote("penny")?.contains("0.0432") == true)
check("a row with no name still answers", await about("penny") == "close 18 Sep")

// The whole point of the dollar rule: short tickers are real words. Without it
// "it" and "f" would put a price under half of what anyone types.
check("a one letter ticker needs a dollar", await quote("f") == nil)
check("a two letter ticker needs a dollar", await quote("it") == nil)
check("with the dollar it resolves", await quote("$f")?.hasPrefix("F  ") == true)
check("and so does the two letter one", await quote("$it")?.hasPrefix("IT  ") == true)

// Everything a launcher gets typed into it that is not a ticker.
for miss in ["hello", "5 + 5", "100 usd in eur", "what should i have for lunch",
             "am i free tomorrow", "disk space", "zzzz", "3 miles in km", "$",
             "2 + 2", "20c", "5 km"] {
    check("falls through: \(miss)", await quote(miss) == nil)
}

// Against the real published files when they are on disk. A fixture only proves
// the decoder matches the fixture; this proves it matches what the lab actually
// serves, which is what breaks when a key is renamed on the server.
let liveShares = LabAPI.cached("markets", as: Markets.Shares.self)?.data
let liveCoins = LabAPI.cached("crypto", as: Markets.Coins.self)?.data
if liveShares != nil || liveCoins != nil {
    print("markets, live files")
    await Markets.shared.adopt(shares: liveShares, coins: liveCoins,
                               fiat: Currency.table())
    check("the currency table is loaded too", Currency.table() != nil)
    check("thousands of shares", (liveShares?.stocks.count ?? 0) > 3000)
    check("a useful set of coins", (liveCoins?.coins.count ?? 0) > 50)
    check("apple resolves", await quote("aapl")?.hasPrefix("AAPL") == true)
    check("so does its name", await quote("apple")?.hasPrefix("AAPL") == true)
    check("btc is live, not a close", await about("btc")?.contains("live") == true)
    check("btc is the coin, not the etf", await about("btc")?.hasPrefix("Bitcoin,") == true)
    check("abt is the company, not the token", await about("abt")?.hasPrefix("Abbott") == true)
    // DASH is DoorDash and also Dash. Both are offered rather than guessed at,
    // and the coin leads because it is the live number.
    let both = await Markets.shared.quotes(for: "dash")
    check("a clashing symbol gives both", both.count == 2)
    check("the coin leads", both.first?.asOf.contains("live") == true)
    check("the share follows", both.last?.asOf.contains("close") == true)
    check("an unclashed symbol gives one", await Markets.shared.quotes(for: "aapl").count == 1)
    for miss in ["safari", "battery", "am i free tomorrow", "disk space"] {
        check("launcher query is untouched: \(miss)", await quote(miss) == nil)
    }

    // A model answered "1 eth to sol" with 66, off by nearly three times, from
    // prices it remembered rather than looked up. This is the arithmetic done
    // on the numbers we actually hold.
    let eth = liveCoins?.coins["ETH"]?.c ?? 0
    let sol = liveCoins?.coins["SOL"]?.c ?? 1
    let swap = await Markets.shared.convert("1 eth to sol")
    check("a coin pair converts", swap != nil)
    let printed = Double((swap?.value ?? "").split(separator: " ").first?
        .replacingOccurrences(of: ",", with: "") ?? "") ?? 0
    check("it names the target coin", swap?.value.hasSuffix(" SOL") == true)
    // Within a tenth of a percent, because the printed figure is rounded.
    check("and the number is the table's, not a guess",
          eth > 0 && abs(printed - eth / sol) / (eth / sol) < 0.001)
    check("it says the number is live", swap?.asOf.hasPrefix("live") == true)
    check("dollars work as a side", await Markets.shared.convert("2 btc in usd") != nil)
    check("and the other side", await Markets.shared.convert("1000 usd in btc") != nil)
    // Fiat belongs to the table with ninety eight central banks behind it.
    check("fiat is left to the rates table",
          await Markets.shared.convert("100 usd in eur") == nil)
    check("a unit conversion is left alone",
          await Markets.shared.convert("3 miles in km") == nil)
    // Any pair, across all three tables.
    check("a share into dollars", await Markets.shared.convert("1 aapl in usd") != nil)
    check("a share into a coin", await Markets.shared.convert("1 aapl in btc") != nil)
    check("a currency into a coin", await Markets.shared.convert("500 gbp in eth") != nil)
    check("a coin into a currency", await Markets.shared.convert("1 btc in jpy") != nil)
    check("a share into a share", await Markets.shared.convert("10 aapl in tsla") != nil)

    // The tag names the stalest side. A live coin mixed with yesterday's close
    // is an answer as old as that close, and calling it live would be the same
    // lie in a smaller font.
    check("coin to coin stays live",
          await Markets.shared.convert("1 eth to sol")?.asOf.hasPrefix("live") == true)
    check("anything with a share says close",
          await Markets.shared.convert("1 aapl in btc")?.asOf.hasPrefix("close") == true)
    check("a currency and a coin says rate",
          await Markets.shared.convert("500 gbp in eth")?.asOf.hasPrefix("rate") == true)
} else {
    print("markets, live files: not cached, skipped")
}

print("machine")
// comm reports the executable, which for anything modern is buried in a helper
// bundle. The name people know is the first .app in the path.
let paths = [
    ("/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/152.0/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)", "ChatGPT"),
    ("/Applications/Spotify.app/Contents/Frameworks/Spotify Helper (Renderer).app/Contents/MacOS/Spotify Helper (Renderer)", "Spotify"),
    ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome"),
    ("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", "WindowServer"),
    ("/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", "VirtualMachine"),
    ("/usr/sbin/coreaudiod", "coreaudiod"),
]
for (path, want) in paths {
    check("names \(want)", SystemMonitor.appName(from: path) == want)
}

let now = await SystemMonitor.shared.machine()
check("cpu is a real reading", now.cpu >= 0 && now.cpu <= 100)
check("memory is counted", now.memoryUsed > 0 && now.memoryUsed < now.memoryTotal)
check("disk is counted", now.diskFree > 0 && now.diskFree < now.diskTotal)
check("three cpu rows", now.topCPU.count == 3)
check("three memory rows", now.topMemory.count == 3)
check("no duplicated app", Set(now.topMemory.map(\.name)).count == now.topMemory.count)
print("  cards would read:")
print("    CPU \(now.cpuText)   MEMORY \(now.memoryText)   DISK FREE \(now.diskText)")
for row in now.topCPU { print("    top cpu     \(row.name)  \(row.value)") }
for row in now.topMemory { print("    top memory  \(row.name)  \(row.value)") }

print("emoji")
func emoji(_ q: String) async -> [String] {
    await Emoji.shared.search(q).map(\.character)
}
check("the index loaded", await Emoji.shared.search("fire").count > 0)
check("fire is the flame", await emoji("fire").first == "\u{1F525}")
check("rocket", await emoji("rocket").first == "\u{1F680}")
check("two words narrow it", await emoji("red heart").first == "\u{2764}\u{FE0F}")
check("an alias works", await emoji("lol").contains("\u{1F602}"))
check("+1 is a thumbs up", await emoji("+1").first == "\u{1F44D}")
check("colon form works", await emoji(":fire:").first == "\u{1F525}")
check("saying emoji works", await emoji("emoji fire").first == "\u{1F525}")

// Unasked, only a whole word counts. Otherwise half of what anyone types into a
// launcher drags an emoji row along with it.
check("an app name is left alone", await emoji("safari").isEmpty)
check("a partial needs asking", await emoji("fir").isEmpty)
check("but asking allows it", await emoji("emoji fir").isEmpty == false)
check("a two letter partial is not enough", await emoji("fi").isEmpty)
check("but two letters exact is fine", await emoji("ok").isEmpty == false)
for miss in ["5 + 5", "100 usd in eur", "am i free tomorrow", "1 eth to sol"] {
    check("falls through: \(miss)", await emoji(miss).isEmpty)
}
print("  fire ->", await emoji("fire").prefix(4).joined(separator: " "))
print("  emoji fi ->", await emoji("emoji fi").prefix(6).joined(separator: " "))

print("tokens")
// A launcher must not hit the network on every keystroke. An address is
// unambiguous; otherwise the person has to say the word.
check("an address is enough",
      Tokens.wanted(in: "0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3")
        == "0xaa07a0e9209e16ac99708c3ec70159c6ef3128a3")
check("saying price is enough", Tokens.wanted(in: "orbio price") == "orbio")
check("so is saying token", Tokens.wanted(in: "orbio token") == "orbio")
check("and the other way round", Tokens.wanted(in: "price of orbio") == "orbio")
for quiet in ["safari", "settings", "btc", "aapl", "5 * 12", "am i free tomorrow",
              "100 usd in eur", "fire", "1 eth to sol", "disk space"] {
    check("stays off the wire: \(quiet)", Tokens.wanted(in: quiet) == nil)
}
check("a short stem is ignored", Tokens.wanted(in: "a price") == nil)
check("a near address is not one", Tokens.isAddress("0xAa07A0e9209e16aC99708C3EC70159c6eF3128") == false)

// Solana is base58 with no 0x, so the EVM check alone made those unfindable.
check("a solana address counts",
      Tokens.isAddress("A18GrBLPSWUGg1pp3tg9oJU2KBQrkkKiyykL21b4u22i"))
check("and usdc on solana",
      Tokens.isAddress("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"))
check("a solana address goes straight through",
      Tokens.wanted(in: "A18GrBLPSWUGg1pp3tg9oJU2KBQrkkKiyykL21b4u22i")
        == "A18GrBLPSWUGg1pp3tg9oJU2KBQrkkKiyykL21b4u22i")
// Case carries meaning in base58, so folding it would break the lookup.
check("its case is kept",
      Tokens.wanted(in: "A18GrBLPSWUGg1pp3tg9oJU2KBQrkkKiyykL21b4u22i")?
        .contains("GrBLPSWUGg") == true)
// An EVM address is hex, so case there means nothing and folds as before.
check("an evm address still folds",
      Tokens.wanted(in: "0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3")
        == "0xaa07a0e9209e16ac99708c3ec70159c6ef3128a3")
// base58 drops 0, O, I and l on purpose.
check("base58 rejects a zero",
      Tokens.isAddress("018GrBLPSWUGg1pp3tg9oJU2KBQrkkKiyykL21b4u22i") == false)
check("an ordinary word is not an address", Tokens.isAddress("orbio") == false)
check("nor is a long sentence",
      Tokens.isAddress("what should i have for lunch today please") == false)
check("nor is a wrong character", Tokens.isAddress("0xZZ07A0e9209e16aC99708C3EC70159c6eF3128A3") == false)

// Prices here run from a fraction of a cent to thousands.
check("a sub cent token keeps its digits", Tokens.money(0.0000198).contains("0.0000198"))
check("a normal price rounds", Tokens.money(0.052752) == "$0.0528")
check("liquidity reads short", Tokens.short(1_691_658) == "$1.7m")
check("and so do the small ones", Tokens.short(15_343) == "$15k")

// Following and pinning are different. Following keeps a price so the symbol
// answers offline; pinning also puts it on the empty screen.
let heldWatched = Settings.watchedTokens
let heldPinned = Settings.pinnedTokens
Settings.watchedTokens = []
Settings.pinnedTokens = []
let one = "0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3"
Settings.addToken(one)
Settings.addToken(one.lowercased())
check("adding twice keeps one", Settings.watchedTokens.count == 1)
check("and it is followed", Settings.isWatched(one.uppercased()))
check("but not pinned", Settings.isPinned(one) == false)
Settings.setPinned(one, true)
check("pinning it works", Settings.isPinned(one))
check("and pinning does not duplicate the follow", Settings.watchedTokens.count == 1)
Settings.setPinned(one, false)
check("unpinning keeps it followed", !Settings.isPinned(one) && Settings.isWatched(one))
// Pinning something never followed follows it too, so one keystroke is enough.
let two = "0x232CDFc415D10b673845D83Dc02ba2eaBe7e30d1"
Settings.setPinned(two, true)
check("pinning a new one follows it", Settings.isWatched(two) && Settings.isPinned(two))
Settings.removeToken(two)
check("removing clears both", !Settings.isWatched(two) && !Settings.isPinned(two))
// A pin for something no longer followed must not survive as a ghost.
Settings.setPinned(one, true)
Settings.watchedTokens = []
check("a pin without a follow is dropped", Settings.pinnedTokens.isEmpty)
Settings.watchedTokens = heldWatched
Settings.pinnedTokens = heldPinned

print("")
print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
